"""Shared suite paths and update lock, compatible with the PowerShell updater."""
import contextlib
import ctypes
import os
from pathlib import Path

HOME = Path(__file__).resolve().parent
SUITE = HOME.parent.parent
DATA_ROOT = Path(os.environ.get("VOCAL_DATA_ROOT", str(SUITE)))
SETTINGS = Path(os.environ.get("VOCAL_SETTINGS_PATH", str(DATA_ROOT / "work/vocal-remover/ui-settings.json")))


@contextlib.contextmanager
def use_lock():
    if os.name != "nt" or not (SUITE / "AppUpdate.Core.ps1").is_file():
        yield
        return
    from ctypes import wintypes
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.CreateFileW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD,
        wintypes.LPVOID, wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE]
    kernel.CreateFileW.restype = wintypes.HANDLE
    kernel.CloseHandle.argtypes = [wintypes.HANDLE]
    path = SUITE / "work/application.lock"
    path.parent.mkdir(parents=True, exist_ok=True)
    handle = kernel.CreateFileW(str(path), 0xC0000000, 3, None, 4, 0x80, None)
    if handle == ctypes.c_void_p(-1).value:
        raise RuntimeError("Ứng dụng đang cập nhật. Đợi cập nhật xong rồi mở Vocal Remover.")
    try:
        yield
    finally:
        kernel.CloseHandle(handle)


def version():
    try:
        return (SUITE / "VERSION.txt").read_text(encoding="utf-8-sig").splitlines()[0].strip()
    except (OSError, IndexError):
        return ""
