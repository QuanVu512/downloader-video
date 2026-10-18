"""Real curl requests: contiguous resume, failed/ignored Range and slow CDN failover."""
import json
import os
from pathlib import Path
import socket
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

APP = Path(__file__).resolve().parent.parent
RUN = APP / 'tests/work' / ('curl-' + str(os.getpid()))
RUN.mkdir(parents=True)
DATA = bytes(range(256)) * 4096
REQUESTS = []
PS = Path(os.environ['WINDIR']) / 'System32/WindowsPowerShell/v1.0/powershell.exe'
ENV = {k: v for k, v in os.environ.items() if k.lower() != 'psmodulepath'}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        mode = urlparse(self.path).path.strip('/')
        raw_range = self.headers.get('Range', '')
        start = int(raw_range.removeprefix('bytes=').split('-')[0]) if raw_range else 0
        range_end = raw_range.split('-')[1] if raw_range else ''
        end = min(int(range_end), len(DATA)-1) if range_end else len(DATA)-1
        REQUESTS.append((mode, start, self.headers.get('Referer'), self.headers.get('User-Agent')))
        if mode == 'error':
            self.send_response(403)
            self.send_header('Content-Length', '5')
            self.end_headers()
            self.wfile.write(b'error')
            return
        if start >= len(DATA):
            self.send_response(416)
            self.send_header('Content-Range', f'bytes */{len(DATA)}')
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        actual_start = 0 if mode in ('ignore', 'wrong') else start
        if mode == 'ignore':
            end = len(DATA)-1
        self.send_response(206 if raw_range and mode != 'ignore' else 200)
        if raw_range and mode != 'ignore':
            self.send_header('Content-Range', f'bytes {actual_start}-{end}/{len(DATA)}')
        self.send_header('Content-Length', str(end - actual_start + 1 + (16 if mode == 'oversize' else 0)))
        self.end_headers()
        try:
            if mode == 'drop':
                self.wfile.write(DATA[actual_start:actual_start + 65536])
                self.wfile.flush()
                self.connection.shutdown(socket.SHUT_RDWR)
                self.connection.close()
            elif mode == 'slow':
                for offset in range(actual_start, end+1, 512):
                    self.wfile.write(DATA[offset:offset + 512])
                    self.wfile.flush()
                    time.sleep(0.5)
            else:
                self.wfile.write(DATA[actual_start:end+1] + (b'x' * 16 if mode == 'oversize' else b''))
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass


runner = RUN / 'invoke.ps1'
runner.write_text('''param($Core,$Url,$Path,$Directory,$ResultFile,[long]$Size=0,[int]$Speed=262144,[int]$Seconds=30,[long]$ChunkBytes=8388608)
$ErrorActionPreference='Stop'
. $Core
$curl=(Get-Command curl.exe -CommandType Application | Select-Object -First 1).Source
$progress=New-Object 'Collections.Generic.List[long]'
$result=Invoke-CurlDownload -Executable $curl -Url $Url -Path $Path -Directory $Directory -ExpectedSize $Size -Headers @{Referer='https://www.bilibili.com/';'User-Agent'='Bili-curl-test'} -LowSpeedLimit $Speed -LowSpeedSeconds $Seconds -ChunkBytes $ChunkBytes -OnProgress {param($bytes) [void]$progress.Add($bytes)}
@{result=$result;progress=$progress.ToArray()} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $ResultFile -Encoding UTF8
''', encoding='utf-8-sig')
server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
BASE = f'http://127.0.0.1:{server.server_port}'


def invoke(name, mode, prefix=b'', expected=len(DATA), speed=262144, seconds=30, path=None, chunk_bytes=8388608):
    folder = RUN / name
    folder.mkdir(exist_ok=True)
    path = path or folder / 'kiểm tra [1].part'
    if prefix:
        path.write_bytes(prefix)
    result_path = folder / 'result.json'
    command = [str(PS), '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', str(runner),
               '-Core', str(APP / 'Downloader.Core.ps1'), '-Url', BASE + '/' + mode + '?token=secret',
               '-Path', str(path), '-Directory', str(folder), '-ResultFile', str(result_path),
               '-Size', str(expected), '-Speed', str(speed), '-Seconds', str(seconds), '-ChunkBytes', str(chunk_bytes)]
    run = subprocess.run(command, capture_output=True, timeout=25, env=ENV)
    assert run.returncode == 0, run.stdout.decode(errors='replace') + run.stderr.decode(errors='replace')
    payload = json.loads(result_path.read_text(encoding='utf-8-sig'))
    assert 'token=secret' not in payload['result']['Details']
    assert not list(folder.glob('*.curl.conf*')), 'Signed URL/header scratch files must be removed'
    return payload, path


try:
    result, path = invoke('fresh', 'good')
    assert result['result']['ExitCode'] == 0 and path.read_bytes() == DATA
    result, path = invoke('resume', 'good', DATA[:131072])
    assert result['result']['ExitCode'] == 0 and path.read_bytes() == DATA
    assert REQUESTS[-1][1] == 131072
    assert REQUESTS[-1][2:] == ('https://www.bilibili.com/', 'Bili-curl-test')
    result, path = invoke('chunk-first', 'good', chunk_bytes=524288)
    assert result['result']['ExitCode'] == 0 and not result['result']['Complete']
    assert path.read_bytes() == DATA[:524288]
    result, path = invoke('chunk-second', 'good', path=path, chunk_bytes=524288)
    assert result['result']['ExitCode'] == 0 and result['result']['Complete'] and path.read_bytes() == DATA
    assert REQUESTS[-1][1] == 524288
    for mode in ('ignore', 'wrong', 'error', 'oversize'):
        result, path = invoke(mode, mode, DATA[:131072])
        assert result['result']['ExitCode'] != 0 and path.read_bytes() == DATA[:131072], mode
    result, path = invoke('drop', 'drop', DATA[:131072])
    assert result['result']['ExitCode'] != 0 and 131072 < path.stat().st_size < len(DATA)
    resume_offset = path.stat().st_size
    result, path = invoke('resume-after-drop', 'good', path=path)
    assert result['result']['ExitCode'] == 0 and path.read_bytes() == DATA
    assert REQUESTS[-1][1] == resume_offset
    result, path = invoke('already-complete', 'good', DATA)
    assert result['result']['ExitCode'] == 0 and path.read_bytes() == DATA
    result, path = invoke('wrong-size', 'good', DATA[:131072], expected=len(DATA) + 1)
    assert result['result']['ExitCode'] != 0 and path.read_bytes() == DATA[:131072]
    result, path = invoke('slow', 'slow', speed=4096, seconds=2)
    assert result['result']['ExitCode'] == 28 and 0 < path.stat().st_size < len(DATA)
    assert result['progress'], 'Progress must be emitted during transfer'
    result, path = invoke('switch-after-slow', 'good', path=path)
    assert result['result']['ExitCode'] == 0 and path.read_bytes() == DATA
    print('TOTAL PASS 14 curl integration checks', flush=True)
finally:
    server.shutdown()
