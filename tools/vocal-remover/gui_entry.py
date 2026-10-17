"""Windowed entry point with a visible startup error instead of silent failure."""
from pathlib import Path
import traceback


def main():
    try:
        from app import main as start
        start()
    except Exception:
        log = Path(__file__).resolve().parent / "startup-error.log"
        details = traceback.format_exc()
        try:
            log.write_text(details, encoding="utf-8")
            message = "Không mở được Vocal Remover. Chi tiết lỗi tại:\n" + str(log)
        except OSError:
            message = details
        import ctypes
        ctypes.windll.user32.MessageBoxW(None, message, "Vocal Remover Auto", 0x10)
        raise SystemExit(1)


if __name__ == "__main__":
    main()
