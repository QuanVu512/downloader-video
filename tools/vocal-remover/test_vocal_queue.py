"""Integration tests exercise real FFmpeg I/O with an explicitly fake separator."""
import json
from pathlib import Path
import tempfile
import threading
import unittest

import numpy as np
import soundfile as sf

import vocal_queue as vq


class IdentityEngine:
    calls = 0

    def __init__(self, *args):
        pass

    def separate(self, wave, stop=None, progress=None):
        type(self).calls += 1
        return wave.copy()


class QueueTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="vocal-queue-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.model = self.root / "fixture.onnx"
        self.model.write_bytes(b"not-a-real-model; used only with injected IdentityEngine")
        import hashlib
        key = hashlib.md5(self.model.read_bytes()).hexdigest()
        metadata = self.root / "model_data"
        metadata.mkdir()
        (metadata / "model_data.json").write_text(json.dumps({key: {
            "compensate": 1.035, "mdx_dim_f_set": 3072, "mdx_dim_t_set": 8,
            "mdx_n_fft_scale_set": 6144, "primary_stem": "Instrumental"}}))
        frames = vq.RATE * 33 + 137
        t = np.arange(frames, dtype=np.float32) / vq.RATE
        self.wave = np.stack([.2 * np.sin(2 * np.pi * 331 * t),
                              .15 * np.sin(2 * np.pi * 611 * t)], axis=1)
        self.source = self.root / "source.wav"
        sf.write(self.source, self.wave, vq.RATE, subtype="FLOAT")
        self.output = self.root / "result.wav"
        self.work = self.root / "work"
        IdentityEngine.calls = 0

    def run_job(self, **kwargs):
        return vq.run_job(self.source, self.output, self.model, work_root=self.work,
                          seconds=15, context=1, engine_factory=kwargs.pop("engine", IdentityEngine), **kwargs)

    def state(self):
        path = next(self.work.glob("*/state.json"))
        return path, json.loads(path.read_text(encoding="utf-8"))

    def test_sample_exact_crossfade_and_resume(self):
        state = self.run_job()
        actual, rate = sf.read(self.output, dtype="float32")
        self.assertEqual(rate, vq.RATE)
        self.assertEqual(actual.shape, self.wave.shape)
        self.assertLess(np.max(np.abs(actual - self.wave)), 1 / 32768 + 1e-6)
        self.assertEqual(state["stats"]["frames"], len(self.wave))
        self.assertEqual(IdentityEngine.calls, 3)
        self.run_job()
        self.assertEqual(IdentityEngine.calls, 3)

    def test_failure_then_continue_skips_completed_part(self):
        class Fails(IdentityEngine):
            calls = 0
            def separate(self, wave, *args):
                type(self).calls += 1
                if self.calls == 2:
                    raise MemoryError("synthetic out of memory")
                return wave
        with self.assertRaises(MemoryError):
            self.run_job(engine=Fails)
        _, state = self.state()
        self.assertEqual(state["status"], "failed")
        self.assertIn("sha256", state["parts"][0])
        self.assertFalse(self.output.exists())
        self.run_job()
        self.assertEqual(IdentityEngine.calls, 2)

    def test_cancel_keeps_completed_part(self):
        stop = threading.Event()
        def emit(event):
            if event.get("part") == 2 and event["state"] == "processing":
                stop.set()
        with self.assertRaises(vq.Cancelled):
            self.run_job(stop=stop, emit=emit)
        _, state = self.state()
        self.assertIn("sha256", state["parts"][0])
        self.assertNotIn("sha256", state["parts"][1])
        self.run_job()
        self.assertTrue(self.output.exists())

    def test_corrupt_part_is_processed_again(self):
        class FailSecond(IdentityEngine):
            calls = 0
            def separate(self, wave, *args):
                type(self).calls += 1
                if self.calls > 1:
                    raise RuntimeError("stop")
                return wave
        with self.assertRaises(RuntimeError):
            self.run_job(engine=FailSecond)
        path, state = self.state()
        part = path.parent / state["parts"][0]["file"]
        with part.open("r+b") as stream:
            stream.seek(-16, 2)
            stream.write(b"corrupt-the-data")
        self.run_job()
        self.assertEqual(IdentityEngine.calls, 3)

    def test_existing_output_preserved(self):
        self.output.write_bytes(b"user-file-do-not-replace")
        with self.assertRaises(FileExistsError):
            self.run_job()
        self.assertEqual(self.output.read_bytes(), b"user-file-do-not-replace")

    def test_output_after_publish_crash_recovers(self):
        self.run_job()
        path, state = self.state()
        state["status"] = "publishing"
        vq.save_json(path, state)
        recovered = self.run_job()
        self.assertEqual(recovered["status"], "complete")
        self.assertEqual(IdentityEngine.calls, 3)

    def test_job_lock(self):
        with vq.job_lock(self.work):
            with self.assertRaises(RuntimeError):
                with vq.job_lock(self.work):
                    self.fail("must not acquire lock twice")
        with vq.job_lock(self.work):
            pass

    def test_changed_source_never_reuses_old_parts(self):
        self.run_job()
        changed = self.root / "changed-output.wav"
        sf.write(self.source, self.wave * .5, vq.RATE, subtype="FLOAT")
        vq.run_job(self.source, changed, self.model, work_root=self.work,
                   seconds=15, context=1, engine_factory=IdentityEngine)
        self.assertEqual(IdentityEngine.calls, 6)

    def test_nan_output_rejected(self):
        class NaN(IdentityEngine):
            def separate(self, wave, *args):
                wave[0, 0] = np.nan
                return wave
        with self.assertRaisesRegex(RuntimeError, "không hợp lệ"):
            self.run_job(engine=NaN)
        self.assertFalse(self.output.exists())

    def test_chunk_memory_bound_independent_of_duration(self):
        for hours in [1, 6, 24]:
            parts = vq.parts_for(vq.RATE * 3600 * hours + 1)
            self.assertEqual(parts[0]["start"], 0)
            self.assertEqual(parts[-1]["end"], vq.RATE * 3600 * hours + 1)
            self.assertLessEqual(max(p["end"] - p["start"] for p in parts), 132 * vq.RATE)

    def test_short_input_and_flac(self):
        sf.write(self.source, self.wave[:743], vq.RATE, subtype="FLOAT")
        output = self.root / "short.flac"
        state = vq.run_job(self.source, output, self.model, work_root=self.work,
                           seconds=15, context=1, engine_factory=IdentityEngine)
        self.assertEqual(state["frames"], 743)
        self.assertEqual(sf.info(output).frames, 743)

    def test_rejects_wrong_stem_metadata(self):
        file = self.root / "model_data/model_data.json"
        data = json.loads(file.read_text())
        next(iter(data.values()))["primary_stem"] = "Vocals"
        file.write_text(json.dumps(data))
        with self.assertRaises(ValueError):
            self.run_job()

    def test_stft_bounded_engine_does_not_infer_padding_only_windows(self):
        from scipy import signal
        engine = vq.MDXEngine.__new__(vq.MDXEngine)
        engine.config = {"dim_f": 3072, "frames": 256, "compensate": 1.0}
        engine.n_fft, engine.hop, engine.trim = 6144, 1024, 3072
        engine.length = 1024 * 255
        engine.step = engine.length - engine.n_fft
        engine.window = signal.windows.hann(6144, sym=False).astype(np.float32)
        class Input:
            name = "input"
        class IdentitySession:
            calls = 0
            def run(self, _, feeds):
                self.calls += 1
                return [feeds["input"]]
        engine.input = Input()
        engine.session = IdentitySession()
        # 743 samples used to trigger an entirely padded second inference.
        result = engine.separate(self.wave[:743])
        self.assertEqual(engine.session.calls, 1)
        self.assertEqual(result.shape, (743, 2))
        self.assertTrue(np.isfinite(result).all())


if __name__ == "__main__":
    unittest.main(verbosity=2)
