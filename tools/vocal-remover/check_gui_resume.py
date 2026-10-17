"""Exercise the GUI -> worker -> complete path on an already completed job."""
import argparse
from pathlib import Path
import time
import tkinter as tk
import tempfile

from app import App


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--chunk-seconds", type=int, default=120)
    args = parser.parse_args()
    if not args.input.is_file() or not args.output.is_file():
        raise ValueError("Phép thử chỉ nhận công việc đã hoàn tất, không tạo job xử lý mới.")
    root = tk.Tk()
    root.withdraw()
    temporary = tempfile.TemporaryDirectory(prefix="vocal-gui-check-")
    app = App(root, settings_path=Path(temporary.name) / "settings.json")
    app.source.set(str(args.input.resolve()))
    app.output.set(str(args.output.resolve()))
    app.seconds.set(str(args.chunk_seconds))
    app.start()
    deadline = time.monotonic() + 45
    try:
        while time.monotonic() < deadline:
            root.update()
            if app.process and app.process.poll() is not None and float(app.bar["value"]) == 100:
                assert app.process.returncode == 0
                assert app.percent.get() == "100%"
                assert app.result == args.output.resolve()
                assert str(app.listen_button["state"]) == "normal"
                print("GUI worker resume PASS")
                return
            time.sleep(.05)
        app.stop()
        raise RuntimeError("GUI không nhận được kết quả hoàn tất trong 45 giây.")
    finally:
        root.destroy()
        temporary.cleanup()


if __name__ == "__main__":
    main()
