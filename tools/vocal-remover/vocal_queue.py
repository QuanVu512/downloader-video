"""Bounded, resumable MDX instrumental extraction. No UVR GUI automation."""
from __future__ import annotations

import argparse
import contextlib
import ctypes
import hashlib
import json
import math
import os
from pathlib import Path
import shutil
import subprocess
import sys
import threading
import time
from suite_runtime import DATA_ROOT, use_lock

# Set before importing numeric runtimes. ORT also receives an explicit thread limit.
os.environ.setdefault("OMP_NUM_THREADS", "2")
os.environ.setdefault("OPENBLAS_NUM_THREADS", "2")
os.environ.setdefault("MKL_NUM_THREADS", "2")

import numpy as np
import soundfile as sf
from scipy import signal

VERSION = "0.1.0"
RATE = 44100
HOME = Path(__file__).resolve().parent
ROOT = DATA_ROOT
DEFAULT_UVR = Path(os.environ.get("LOCALAPPDATA", "")) / "Programs/Ultimate Vocal Remover"
MODEL_NAME = "UVR-MDX-NET-Inst_HQ_1.onnx"


class Cancelled(Exception):
    pass


def check_stop(stop):
    if stop and stop.is_set():
        raise Cancelled("Đã dừng; tiến độ đã hoàn tất được giữ lại.")


def sha256(path):
    h = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def save_json(path, data):
    path = Path(path)
    tmp = path.with_suffix(path.suffix + ".tmp")
    with tmp.open("w", encoding="utf-8") as stream:
        json.dump(data, stream, ensure_ascii=False, indent=2)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(tmp, path)


def find_ffmpeg():
    found = shutil.which("ffmpeg")
    if found:
        return found
    raise RuntimeError("Không tìm thấy ffmpeg trong PATH. Cài FFmpeg rồi mở lại ứng dụng.")


def check_disk_space(source, directory, output, ffmpeg, seconds, context, emit):
    """Conservative preflight for compressed inputs; no duration-sized RAM buffers."""
    ffprobe = Path(ffmpeg).with_name("ffprobe.exe" if os.name == "nt" else "ffprobe")
    if not ffprobe.exists():
        return
    probe = subprocess.run([str(ffprobe), "-v", "error", "-select_streams", "a:0",
        "-show_entries", "stream=duration:format=duration", "-of", "json", str(source)],
        capture_output=True, text=True, timeout=60,
        creationflags=0x08000000 if os.name == "nt" else 0)
    if probe.returncode:
        raise RuntimeError("Không đọc được audio đầu vào bằng FFprobe.")
    metadata = json.loads(probe.stdout)
    streams = metadata.get("streams", [])
    if not streams:
        raise ValueError("File đầu vào không có luồng audio.")
    value = streams[0].get("duration", metadata.get("format", {}).get("duration"))
    try:
        duration = float(value)
    except (TypeError, ValueError):
        return
    if not math.isfinite(duration) or duration <= 0:
        return
    output_disk = output.parent
    while not output_disk.exists():
        output_disk = output_disk.parent
    frames = math.ceil(duration * RATE)
    work_bytes = int(frames * (20 + 16 * context / seconds))
    output_bytes = frames * 4
    reserve = 256 * 1024**2
    if os.stat(directory).st_dev == os.stat(output_disk).st_dev:
        requirements = [(directory, work_bytes + output_bytes)]
    else:
        requirements = [(directory, work_bytes), (output_disk, output_bytes)]
    for location, amount in requirements:
        if shutil.disk_usage(location).free < amount + reserve:
            raise RuntimeError(f"Không đủ ổ đĩa tại {location.anchor}: cần thêm khoảng "
                               f"{(amount + reserve) / 1024**3:.1f} GiB cho dữ liệu tạm và đầu ra.")
    emit({"state": "disk_check", "message": f"Dữ liệu tạm và đầu ra dự kiến tối đa khoảng "
          f"{(work_bytes + output_bytes) / 1024**3:.1f} GiB; file gốc được giữ nguyên."})


@contextlib.contextmanager
def job_lock(directory):
    """OS releases the lock after a crash; a stale filename never blocks resume."""
    directory.mkdir(parents=True, exist_ok=True)
    with (directory / "job.lock").open("a+b") as stream:
        if os.fstat(stream.fileno()).st_size == 0:
            stream.write(b"0")
            stream.flush()
        stream.seek(0)
        try:
            if os.name == "nt":
                import msvcrt
                msvcrt.locking(stream.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as exc:
            raise RuntimeError("Công việc này đang được một tiến trình khác xử lý.") from exc
        try:
            yield
        finally:
            stream.seek(0)
            if os.name == "nt":
                msvcrt.locking(stream.fileno(), msvcrt.LK_UNLCK, 1)
            else:
                fcntl.flock(stream, fcntl.LOCK_UN)


def model_config(model):
    model = Path(model).resolve(strict=True)
    # UVR identifies model metadata by MD5 of the last 10,000 KiB.
    with model.open("rb") as stream:
        stream.seek(max(0, model.stat().st_size - 10000 * 1024))
        model_hash = hashlib.md5(stream.read()).hexdigest()
    metadata_dir = model.parent / "model_data"
    per_model = metadata_dir / (model_hash + ".json")
    if per_model.exists():
        data = json.loads(per_model.read_text(encoding="utf-8-sig"))
    else:
        all_data = json.loads((metadata_dir / "model_data.json").read_text(encoding="utf-8-sig"))
        data = all_data.get(model_hash)
    if not data or data.get("primary_stem") != "Instrumental":
        raise ValueError("Bản này chỉ nhận model MDX ONNX có primary_stem=Instrumental và metadata UVR hợp lệ.")
    return {"n_fft": int(data["mdx_n_fft_scale_set"]),
            "dim_f": int(data["mdx_dim_f_set"]),
            "frames": 2 ** int(data["mdx_dim_t_set"]),
            "compensate": float(data["compensate"])}


class MDXEngine:
    """Native ONNX shape, CPU, batch=1. The session is reused across all parts."""
    def __init__(self, model, config, threads=2):
        import onnxruntime as ort
        options = ort.SessionOptions()
        options.intra_op_num_threads = threads
        options.inter_op_num_threads = 1
        options.execution_mode = ort.ExecutionMode.ORT_SEQUENTIAL
        options.enable_cpu_mem_arena = False
        options.enable_mem_pattern = False
        self.session = ort.InferenceSession(str(model), sess_options=options,
                                            providers=["CPUExecutionProvider"])
        self.input = self.session.get_inputs()[0]
        expected = [1, 4, config["dim_f"], config["frames"]]
        for actual, wanted in zip(self.input.shape, expected):
            if isinstance(actual, int) and actual != wanted:
                raise ValueError(f"Shape model {self.input.shape} không khớp metadata {expected}")
        if len(self.input.shape) != 4:
            raise ValueError("Model không phải MDX-Net spectrogram 4 chiều.")
        self.config = config
        self.n_fft = config["n_fft"]
        self.hop = 1024
        self.trim = self.n_fft // 2
        self.length = self.hop * (config["frames"] - 1)
        self.step = self.length - self.n_fft
        if self.step <= 0:
            raise ValueError("Metadata model không hợp lệ.")
        self.window = signal.windows.hann(self.n_fft, sym=False).astype(np.float32)

    def spectrum(self, wave):
        # Explicit reflection matches torch.stft(center=True, pad_mode='reflect').
        padded = np.pad(wave, ((0, 0), (self.trim, self.trim)), mode="reflect")
        _, _, spec = signal.stft(padded, fs=1, window=self.window, nperseg=self.n_fft,
                                 noverlap=self.n_fft - self.hop, boundary=None, padded=False)
        spec *= self.window.sum()
        return np.stack((spec.real, spec.imag), axis=1).reshape(
            1, 4, self.trim + 1, -1)[:, :, :self.config["dim_f"], :].copy()

    def inverse(self, prediction):
        full = np.zeros((1, 4, self.trim + 1, self.config["frames"]), dtype=np.float32)
        full[:, :, :self.config["dim_f"], :] = prediction
        components = full.reshape(2, 2, self.trim + 1, -1)
        spec = (components[:, 0] + 1j * components[:, 1]) / self.window.sum()
        _, audio = signal.istft(spec, fs=1, window=self.window, nperseg=self.n_fft,
                               noverlap=self.n_fft - self.hop, boundary=True)
        return audio.astype(np.float32, copy=False)

    def separate(self, wave, stop=None, progress=None):
        """Only one bounded external part is in RAM, never the complete source."""
        count = wave.shape[0]
        pad = self.step + self.trim - count % self.step
        mixture = np.pad(wave.T, ((0, 0), (self.trim, pad)))
        result = np.zeros_like(mixture)
        divider = np.zeros(mixture.shape[1], dtype=np.float32)
        # Padding-only windows cannot contribute to any retained output sample.
        starts = range(0, min(mixture.shape[1], self.trim + count), self.step)
        for index, start in enumerate(starts):
            check_stop(stop)
            size = min(self.length, mixture.shape[1] - start)
            chunk = np.pad(mixture[:, start:start + size], ((0, 0), (0, self.length - size)))
            spec = self.spectrum(chunk)
            spec[:, :, :3] = 0
            prediction = self.session.run(None, {self.input.name: spec})[0]
            if prediction.shape != spec.shape or not np.isfinite(prediction).all():
                raise RuntimeError("Model trả về shape sai hoặc giá trị NaN/Inf.")
            audio = self.inverse(prediction)
            window = np.hanning(size).astype(np.float32)
            result[:, start:start + size] += audio[:, :size] * window
            divider[start:start + size] += window
            if progress:
                progress((index + 1) / len(starts))
        region = slice(self.trim, self.trim + count)
        weights = divider[region]
        if np.any(weights <= 0):
            raise RuntimeError("Vùng ghép nội bộ không được phủ đủ.")
        output = (result[:, region] / weights).T.copy()
        output *= self.config["compensate"]
        if not np.isfinite(output).all():
            raise RuntimeError("Audio đầu ra chứa NaN/Inf.")
        return output


def parts_for(frames, seconds=120, context=6):
    size, extra = round(seconds * RATE), round(context * RATE)
    return [{"index": i, "start": max(0, start - extra),
             "end": min(frames, start + size + extra)}
            for i, start in enumerate(range(0, frames, size))]


def audio_ok(path, frames):
    try:
        info = sf.info(str(path))
        return info.frames == frames and info.samplerate == RATE and info.channels == 2
    except (OSError, RuntimeError):
        return False


def decode(source, target, ffmpeg, stop, log):
    temporary = target.with_name("decoded.partial.wav")
    command = [ffmpeg, "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
               "-threads", "2", "-i", str(source), "-map", "0:a:0", "-vn", "-sn", "-dn",
               "-ac", "2", "-ar", str(RATE), "-c:a", "pcm_f32le", "-rf64", "auto", str(temporary)]
    with log.open("wb") as errors:
        process = subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=errors,
                                   creationflags=0x08000000 if os.name == "nt" else 0)
        try:
            while process.poll() is None:
                check_stop(stop)
                time.sleep(0.2)
            if process.returncode:
                raise RuntimeError(f"FFmpeg giải mã thất bại; xem {log}")
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait()
    info = sf.info(str(temporary))
    if info.frames <= 0 or not audio_ok(temporary, info.frames):
        raise RuntimeError("Audio giải mã không hợp lệ.")
    os.replace(temporary, target)
    return info.frames


def merge_parts(parts, directory, target, total_frames, stop=None):
    """Crossfade overlaps without shortening or stretching the source timeline."""
    pending = None
    end = 0
    written = 0
    clipped = 0
    fmt = "FLAC" if target.suffix.lower() == ".flac" else (
        "RF64" if total_frames * 4 >= 0xFFFFFFFF - 1024 else "WAV")
    def write(stream, data):
        nonlocal written, clipped
        check_stop(stop)
        clipped += int(np.count_nonzero(np.abs(data) > 1))
        stream.write(data)
        written += len(data)
    with sf.SoundFile(str(target), "w", samplerate=RATE, channels=2,
                      format=fmt, subtype="PCM_16") as stream:
        for part in parts:
            check_stop(stop)
            if part.get("sha256") and sha256(directory / part["file"]) != part["sha256"]:
                raise RuntimeError("Checksum của phần audio đã thay đổi trước khi ghép.")
            data, rate = sf.read(str(directory / part["file"]), dtype="float32", always_2d=True)
            if (len(data) != part["end"] - part["start"] or rate != RATE
                    or data.shape[1] != 2 or not np.isfinite(data).all()):
                raise RuntimeError("Phần audio bị thay đổi trước khi ghép.")
            if pending is not None:
                overlap = end - part["start"]
                if overlap < 0 or overlap > min(len(pending), len(data)):
                    raise RuntimeError("Ranh giới ghép không hợp lệ.")
                if overlap:
                    write(stream, pending[:-overlap])
                    fade = np.linspace(0, 1, overlap, dtype=np.float32)[:, None]
                    data[:overlap] = pending[-overlap:] * (1 - fade) + data[:overlap] * fade
                else:
                    write(stream, pending)
            elif part["start"] != 0:
                raise RuntimeError("Thiếu phần audio đầu tiên.")
            pending, end = data, part["end"]
        if pending is not None:
            write(stream, pending)
    if written != total_frames or not audio_ok(target, total_frames):
        raise RuntimeError(f"Sai số mẫu sau ghép: {written} != {total_frames}")
    return {"frames": written, "clipped_samples": clipped, "format": fmt}


def peak_memory_mib():
    if os.name != "nt":
        return None
    from ctypes import wintypes
    class Counters(ctypes.Structure):
        _fields_ = [("cb", wintypes.DWORD), ("PageFaultCount", wintypes.DWORD)] + [
            (name, ctypes.c_size_t) for name in ["PeakWorkingSetSize", "WorkingSetSize",
            "QuotaPeakPagedPoolUsage", "QuotaPagedPoolUsage", "QuotaPeakNonPagedPoolUsage",
            "QuotaNonPagedPoolUsage", "PagefileUsage", "PeakPagefileUsage"]]
    counters = Counters()
    counters.cb = ctypes.sizeof(counters)
    ctypes.windll.kernel32.GetCurrentProcess.restype = wintypes.HANDLE
    ctypes.windll.psapi.GetProcessMemoryInfo.argtypes = [wintypes.HANDLE, ctypes.POINTER(Counters), wintypes.DWORD]
    handle = ctypes.windll.kernel32.GetCurrentProcess()
    if ctypes.windll.psapi.GetProcessMemoryInfo(handle, ctypes.byref(counters), counters.cb):
        return round(counters.PeakWorkingSetSize / 1024**2, 1)
    return None


def run_job(source, output, model, *, work_root=None, seconds=120, context=6,
            threads=2, stop=None, emit=None, engine_factory=MDXEngine):
    emit = emit or (lambda event: None)
    source = Path(source).resolve(strict=True)
    output = Path(output).resolve()
    model = Path(model).resolve(strict=True)
    if output == source or output.suffix.lower() not in {".wav", ".flac"}:
        raise ValueError("Đầu ra phải là file WAV/FLAC khác file gốc.")
    if not 15 <= seconds <= 300 or not 1 <= context <= 10 or seconds < context * 3:
        raise ValueError("Độ dài phần: 15–300 giây; vùng nối: 1–10 giây; phần phải dài ít nhất 3 lần vùng nối.")
    if not 1 <= threads <= 4:
        raise ValueError("Chế độ êm máy hỗ trợ 1–4 luồng CPU.")
    started = time.monotonic()
    emit({"state": "checking", "message": "Đang nhận diện nguồn và model..."})
    config = model_config(model)
    identity = {"version": VERSION, "source": str(source), "source_sha256": sha256(source),
                "model": str(model), "model_sha256": sha256(model), "config": config,
                "output": str(output), "seconds": seconds, "context": context}
    key = hashlib.sha256(json.dumps(identity, sort_keys=True).encode()).hexdigest()[:24]
    directory = Path(work_root or ROOT / "work/vocal-remover") / key
    state_path = directory / "state.json"
    with job_lock(directory):
        state = json.loads(state_path.read_text(encoding="utf-8")) if state_path.exists() else {
            "identity": identity, "status": "new", "parts": []}
        if state["identity"] != identity:
            raise RuntimeError("Checkpoint không khớp nguồn hoặc model.")
        if output.exists():
            if (state.get("output_sha256") == sha256(output)
                    and state.get("stats", {}).get("frames") == state.get("frames")
                    and audio_ok(output, state["frames"])):
                state.update(status="complete", output=str(output))
                state.pop("error", None)
                save_json(state_path, state)
                emit({"state": "complete", "message": "Đã xác minh file hoàn tất có sẵn.",
                      "output": str(output), "checkpoint": str(state_path),
                      "output_sha256": state["output_sha256"],
                      "frames": state["frames"], "samplerate": RATE})
                return state
            raise FileExistsError(f"Đầu ra đã tồn tại; chọn tên khác để giữ nguyên file: {output}")
        try:
            check_stop(stop)
            decoded = directory / "decoded.wav"
            if not (state.get("decoded_sha256") and decoded.exists()
                    and sha256(decoded) == state["decoded_sha256"]
                    and audio_ok(decoded, state["frames"])):
                ffmpeg = find_ffmpeg()
                check_disk_space(source, directory, output, ffmpeg, seconds, context, emit)
                emit({"state": "decoding", "message": "Đang giải mã xuống ổ đĩa; không nạp cả file vào RAM."})
                frames = decode(source, decoded, ffmpeg, stop, directory / "ffmpeg.log")
                decoded_hash = sha256(decoded)
                if state.get("decoded_sha256") != decoded_hash:
                    state["parts"] = []
                state.update(frames=frames, decoded_sha256=decoded_hash)
            if not state["parts"]:
                state["parts"] = parts_for(state["frames"], seconds, context)
                for part in state["parts"]:
                    part["file"] = f"part-{part['index']:05d}.wav"
            expected = parts_for(state["frames"], seconds, context)
            for item in expected:
                item["file"] = f"part-{item['index']:05d}.wav"
            if [{key: part.get(key) for key in ("index", "start", "end", "file")}
                    for part in state["parts"]] != expected:
                raise RuntimeError("Danh sách phần trong checkpoint không khớp cấu hình.")
            state["status"] = "processing"
            state.pop("error", None)
            save_json(state_path, state)
            engine = None
            with sf.SoundFile(str(decoded)) as audio:
                for part in state["parts"]:
                    check_stop(stop)
                    destination = directory / part["file"]
                    length = part["end"] - part["start"]
                    if (part.get("sha256") and audio_ok(destination, length)
                            and sha256(destination) == part["sha256"]):
                        emit({"state": "resuming", "part": part["index"] + 1,
                              "message": f"Giữ phần {part['index'] + 1}/{len(state['parts'])} đã hoàn tất."})
                        continue
                    if engine is None:
                        emit({"state": "loading_model", "message": "Đang nạp model một lần, CPU êm máy."})
                        engine = engine_factory(model, config, threads)
                    audio.seek(part["start"])
                    wave = audio.read(length, dtype="float32", always_2d=True)
                    number, total = part["index"] + 1, len(state["parts"])
                    emit({"state": "processing", "part": number, "total": total,
                          "message": f"Đang tách lời phần {number}/{total}."})
                    last_update = [0.0]
                    def progress(value):
                        now = time.monotonic()
                        if now - last_update[0] >= 1 or value == 1:
                            last_update[0] = now
                            emit({"state": "progress", "part": number, "total": total,
                                  "percent": round(100 * (number - 1 + value) / total, 1)})
                    separated = engine.separate(wave, stop, progress)
                    check_stop(stop)
                    if separated.shape != wave.shape or not np.isfinite(separated).all():
                        raise RuntimeError("Model trả về audio không hợp lệ.")
                    temporary = destination.with_suffix(".partial.wav")
                    sf.write(str(temporary), separated, RATE, subtype="FLOAT")
                    os.replace(temporary, destination)
                    part["sha256"] = sha256(destination)
                    save_json(state_path, state)
                    del wave, separated
            state["status"] = "merging"
            save_json(state_path, state)
            emit({"state": "merging", "message": "Đang ghép và xác minh đúng số mẫu audio..."})
            output.parent.mkdir(parents=True, exist_ok=True)
            temporary = directory / ("merged.partial" + output.suffix.lower())
            stats = merge_parts(state["parts"], directory, temporary, state["frames"], stop)
            check_stop(stop)
            # Copy to the output filesystem, then rename without replacing user files.
            publish = output.with_name(output.stem + "." + key + ".partial" + output.suffix)
            with temporary.open("rb") as src, publish.open("wb") as dst:
                shutil.copyfileobj(src, dst, 1024 * 1024)
                dst.flush()
                os.fsync(dst.fileno())
            output_hash = sha256(publish)
            # Record publication intent so a crash after rename can be recovered.
            state.update(status="publishing", output_sha256=output_hash, stats=stats)
            save_json(state_path, state)
            if output.exists():
                raise FileExistsError(f"Đầu ra vừa được tạo bởi tiến trình khác: {output}")
            if os.name == "nt":
                os.rename(publish, output)  # Windows rename refuses existing destinations.
            else:
                os.link(publish, output)
                publish.unlink()
            state.update(status="complete", output=str(output),
                         samplerate=RATE, channels=2,
                         duration_seconds=state["frames"] / RATE,
                         elapsed_seconds=round(time.monotonic() - started, 2),
                         peak_memory_mib=peak_memory_mib())
            save_json(state_path, state)
            emit({"state": "complete", "message": "Hoàn tất, timeline đã xác minh.",
                  "output": str(output), "peak_memory_mib": state["peak_memory_mib"],
                  "seconds": state["duration_seconds"], "checkpoint": str(state_path),
                  "output_sha256": output_hash, "frames": state["frames"], "samplerate": RATE})
            return state
        except BaseException as exc:
            state["status"] = "cancelled" if isinstance(exc, (Cancelled, KeyboardInterrupt)) else "failed"
            state["error"] = str(exc)
            save_json(state_path, state)
            emit({"state": state["status"], "message": str(exc), "checkpoint": str(state_path)})
            raise


def lower_priority():
    if os.name == "nt":
        from ctypes import wintypes
        kernel = ctypes.windll.kernel32
        kernel.GetCurrentProcess.restype = wintypes.HANDLE
        kernel.SetPriorityClass.argtypes = [wintypes.HANDLE, wintypes.DWORD]
        kernel.SetPriorityClass(kernel.GetCurrentProcess(), 0x4000)


def main():
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8", errors="replace")
    parser = argparse.ArgumentParser(description="Tách lời tự động: cắt → hàng đợi → ghép, giữ checkpoint.")
    parser.add_argument("input", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--model", type=Path, default=DEFAULT_UVR / "models/MDX_Net_Models" / MODEL_NAME)
    parser.add_argument("--work-root", type=Path)
    parser.add_argument("--chunk-seconds", type=int, default=120)
    parser.add_argument("--context-seconds", type=int, default=6)
    parser.add_argument("--threads", type=int, default=2)
    parser.add_argument("--stop-file", type=Path, help="Tạo file này để dừng và giữ checkpoint.")
    args = parser.parse_args()
    lower_priority()
    def emit(event):
        print(json.dumps(event, ensure_ascii=False), flush=True)
    class FileStop:
        def is_set(self):
            return bool(args.stop_file and args.stop_file.exists())
    try:
        with use_lock():
            run_job(args.input, args.output, args.model, work_root=args.work_root,
                    seconds=args.chunk_seconds, context=args.context_seconds,
                    threads=args.threads, emit=emit, stop=FileStop())
        return 0
    except KeyboardInterrupt:
        return 130
    except Exception as exc:
        print(json.dumps({"state": "error", "message": str(exc)}, ensure_ascii=False), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
