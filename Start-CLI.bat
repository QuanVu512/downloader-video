@echo off
setlocal
cd /d "%~dp0"
echo Bilibili Downloader - command line.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-Bilibili-Download.ps1" %*
if errorlevel 1 (
  echo.
  echo Co loi. Kiem tra thong bao o tren, sua theo goi y roi chay lai.
  pause
  exit /b 1
)
pause
