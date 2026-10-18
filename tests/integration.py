"""Exercise the real PowerShell worker and aria2 against a local fault server."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import threading
import zipfile
import time
from fixtures import make_video
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

ROOT = Path(__file__).resolve().parent
APP = ROOT.parent
PS = Path(os.environ["WINDIR"]) / "System32/WindowsPowerShell/v1.0/powershell.exe"
# A Python child of pwsh inherits the PowerShell 7 module path. Let Windows
# PowerShell build its own default module path, as Start.bat does from Explorer.
CHILD_ENV = {key: value for key, value in os.environ.items() if key.lower() != "psmodulepath"}
RUN = ROOT / "work" / ("integration-" + str(os.getpid()))
RUN.mkdir()
MOCK = RUN / "mock-extractor.exe"
subprocess.run([str(PS), "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
                str(ROOT / "Compile-Mock.ps1"), "-OutputPath", str(MOCK)], check=True, env=CHILD_ENV)
VIDEO = (ROOT / "work/fixtures/fixture-video.mp4").read_bytes()
AUDIO = (ROOT / "work/fixtures/fixture-audio.m4a").read_bytes()
REQUESTS = []
CASE_VIDEO = {}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        self.serve(True)

    def do_HEAD(self):
        self.serve(False)

    def serve(self, body):
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query)
        mode = query["source"][0]
        if mode == "native":
            mode = "567" if self.headers.get("User-Agent", "").startswith("aria2") else "good"
        case = query["case"][0]
        data = CASE_VIDEO[case] if "30064" in parsed.path else AUDIO
        slow = mode == "slow"
        if slow and self.headers.get("User-Agent", "").startswith(("aria2", "curl")):
            mode = "567"
        start, end = 0, len(data) - 1
        header = self.headers.get("Range", "")
        match = re.fullmatch(r"bytes=(\d+)-(\d*)", header)
        if match:
            start = int(match[1])
            if match[2]:
                end = min(end, int(match[2]))
        REQUESTS.append(dict(case=case, source=mode, range=header, start=start))
        if mode in ("567", "403"):
            self.send_response(int(mode))
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if start >= len(data):
            self.send_response(416)
            self.send_header("Content-Range", f"bytes */{len(data)}")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        self.send_response(206 if match else 200)
        self.send_header("Content-Length", str(end - start + 1))
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Type", "video/mp4")
        if match:
            self.send_header("Content-Range", f"bytes {start}-{end}/{len(data)}")
        self.end_headers()
        if body:
            try:
                if mode == "drop":
                    # Simulate losing the socket after writing data, without fulfilling Content-Length.
                    self.wfile.write(data[start:min(end + 1, start + 32768)])
                    self.wfile.flush()
                    self.connection.shutdown(socket.SHUT_RDWR)
                    self.connection.close()
                elif slow:
                    for offset in range(start, end + 1, 4096):
                        self.wfile.write(data[offset:min(offset + 4096, end + 1)])
                        self.wfile.flush()
                        time.sleep(4096 / (48 * 1024))
                else:
                    self.wfile.write(data[start:end + 1])
            except (BrokenPipeError, ConnectionResetError, OSError):
                pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{server.server_port}"
results = []


def digest(data):
    return hashlib.sha256(data).hexdigest()


def run_case(name, initial, fresh, succeeds=True, expect_refresh=False, real_native=False, native_resume=False, slow=False):
    video_data = make_video(256 * 1024) if slow else VIDEO
    CASE_VIDEO[name] = video_data
    folder = RUN / name
    app = folder / "app"
    tools = app / "tools"
    dest = folder / "output"
    tools.mkdir(parents=True)
    dest.mkdir()
    for source in APP.glob("*.ps1"):
        shutil.copy2(source, app / source.name)
    shutil.copy2(MOCK, tools / "yt-dlp.exe")
    aria = next((APP / "tools").rglob("aria2c.exe"))
    shutil.copy2(aria, tools / "aria2c.exe")
    (tools / "SHA2-256SUMS").write_text(digest(MOCK.read_bytes()) + "  yt-dlp.exe")
    if real_native:
        (tools / "native-tool.txt").write_text(str(APP / "tools/yt-dlp.exe"), encoding="utf-8")
    for tag, sources in (("initial", initial), ("fresh", fresh)):
        urls = [f"{BASE}/40468287381-1-30064.m4s?source={source}&case={name}&token=secret"
                for source in sources]
        audio_url = f"{BASE}/40468287381-1-30280.m4s?source=good&case={name}&token=secret"
        formats = [dict(format_id="30064", height=720, fps=24, vcodec="avc1", acodec="none",
                        ext="mp4", url=urls[0], filesize=len(video_data)),
                   dict(format_id="30280", vcodec="none", acodec="mp4a.40.2", ext="m4a",
                        url=audio_url, tbr=128, filesize=len(AUDIO))]
        info = dict(id="fixture-p1", title="Kiểm thử 中文", duration=4, formats=formats,
                    http_headers={"Referer": "https://www.bilibili.com/"})
        dash = dict(data=dict(dash=dict(video=[dict(baseUrl=urls[0], backupUrl=urls[1:])],
                                       audio=[dict(baseUrl=audio_url, backupUrl=[])])))
        (tools / f"{tag}-info.json").write_text(json.dumps(info, ensure_ascii=False), encoding="utf-8")
        (tools / f"{tag}-dash.json").write_text(json.dumps(dash), encoding="utf-8")
    name_base = "thử nghiệm 中文"
    partial = dest / f"{name_base}_video.mp4.part"
    partial.write_bytes(video_data[:131072])
    original_partial_hash = digest(partial.read_bytes())
    if native_resume:
        (dest / f"{name_base}_video.mp4.native.part").write_bytes(video_data[:0 if slow else 131072])
    identity = "https://www.bilibili.com/video/BV1test/?p=1|fixture-p1|30064|30280"
    manifest = dict(schema=1, identity=identity, video=None, audio=None)
    (dest / f"{name_base}.bilibili.json").write_text(json.dumps(manifest), encoding="utf-8")
    state_path = folder / "state.json"
    command = [str(PS), "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
               str(app / "Start-Bilibili-Download.ps1"), "-Url", "https://www.bilibili.com/video/BV1test/?p=1",
               "-VideoFormatId", "30064", "-FileName", name_base, "-OutputDirectory", str(dest),
               "-StateFile", str(state_path)]
    completed = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=150, env=CHILD_ENV)
    output = completed.stdout.decode("utf-8-sig", errors="replace")
    (folder / "worker.log").write_text(output, encoding="utf-8")
    state = json.loads(state_path.read_text(encoding="utf-8-sig"))
    assert "token=secret" not in output and "token=secret" not in state["message"]
    assert "query hidden] query hidden]" not in output
    assert "không tìm thấy tài nguyên" not in output.lower()
    extracted = int((tools / "extract-count.txt").read_text())
    requests = [r for r in REQUESTS if r["case"] == name]
    if succeeds:
        if not slow and (not real_native or native_resume):
            assert any(r["start"] >= 131072 for r in requests), "Must request a nonzero resume byte"
        assert completed.returncode == 0, output
        assert state["status"] == "complete", state
        assert digest((dest / f"{name_base}_video.mp4").read_bytes()) == digest(video_data)
        assert digest((dest / f"{name_base}_audio.m4a").read_bytes()) == digest(AUDIO)
        with zipfile.ZipFile(dest / f"{name_base}stage1.zip") as package:
            assert sorted(package.namelist()) == sorted([f"{name_base}_video.mp4", f"{name_base}_audio.m4a"])
            assert digest(package.read(f"{name_base}_video.mp4")) == digest(video_data)
            assert digest(package.read(f"{name_base}_audio.m4a")) == digest(AUDIO)
        if real_native:
            assert partial.exists() and digest(partial.read_bytes()) == original_partial_hash
        elif "[curl] Đã xác minh video hoàn tất." in output:
            assert partial.exists() and partial.read_bytes()[:131072] == video_data[:131072]
        else:
            assert not partial.exists()
        if initial[0] == "567":
            assert "HTTP 567" in output
            assert "(1 kết nối" in output
        if expect_refresh:
            assert extracted >= 3, extracted  # Initial video, refreshed video, refreshed audio.
        if slow:
            assert "Chuyển sang HTTP của yt-dlp cho video" in output, "Final native fallback must tolerate a slow connection"
    else:
        assert completed.returncode == 1 and state["status"] == "error", output
        assert partial.exists() and digest(partial.read_bytes()) == original_partial_hash
        assert (dest / f"{name_base}.bilibili.json").exists()
        assert not (dest / f"{name_base}_video.mp4").exists()
        assert not (dest / f"{name_base}stage1.zip").exists()
        assert extracted == 3, extracted
        assert "HTTP 567" in state["message"]
    result = dict(case=name, status="PASS", exit_code=completed.returncode,
                  extraction_count=extracted, requests=requests,
                  video_sha256=digest(video_data) if succeeds else None,
                  audio_sha256=digest(AUDIO) if succeeds else None)
    results.append(result)
    print(f"PASS {name}: exit={completed.returncode}, extractions={extracted}, requests={len(requests)}", flush=True)


try:
    run_case("567-backup-resume", ["567", "good"], ["good"])
    run_case("refresh-after-567", ["567"], ["good"], expect_refresh=True)
    run_case("403-refresh", ["403"], ["good"], expect_refresh=True)
    run_case("disconnect-backup", ["drop", "good"], ["good"])
    run_case("all-cdns-567-preserve", ["567"], ["567"], succeeds=False)
    run_case("curl-fallback", ["567"], ["native"], real_native=True)
    run_case("native-resume", ["good"], ["good"], real_native=True, native_resume=True)
    run_case("slow-native-under-64k", ["slow"], ["slow"], real_native=True, native_resume=True, slow=True)
finally:
    server.shutdown()
    (RUN / "results.json").write_text(json.dumps(results, indent=2), encoding="utf-8")
print(f"TOTAL PASS {len(results)}; evidence={RUN}")
