@echo off
chcp 65001 >nul
cd /d "%~dp0"
where py >nul 2>&1
if %errorlevel%==0 (
  py qifu-cloud-pc.py
) else (
  python qifu-cloud-pc.py
)
echo.
pause
