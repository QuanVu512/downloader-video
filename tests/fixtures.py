"""Generate small structural MP4 fixtures; no downloaded media in source control."""
from pathlib import Path
import struct

def box(kind, data):
    return struct.pack('>I4s', len(data) + 8, kind) + data

def make_media(kind, payload_size):
    duration = bytes(12) + struct.pack('>II', 1000, 4000)
    handler = bytes(8) + kind
    dimensions = struct.pack('>II', 1280 << 16, 720 << 16) if kind == b'vide' else bytes(8)
    track = box(b'trak', box(b'tkhd', dimensions) + box(b'mdia', box(b'mdhd', duration) + box(b'hdlr', handler)))
    media = (bytes(range(256)) * ((payload_size + 255) // 256))[:payload_size]
    return box(b'ftyp', b'isom' + bytes(4) + b'isomiso6') + box(b'moov', box(b'mvhd', duration) + track) + box(b'mdat', media)

def make_video(payload_size=4 * 1024 * 1024):
    return make_media(b'vide', payload_size)

if __name__ == '__main__':
    root = Path(__file__).resolve().parent / 'work/fixtures'
    root.mkdir(parents=True, exist_ok=True)
    (root / 'fixture-video.mp4').write_bytes(make_video())
    (root / 'fixture-audio.m4a').write_bytes(make_media(b'soun', 65536))
    print('Generated structural media fixtures')
