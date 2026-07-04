@echo off
setlocal
set SCRIPT=%~dp0g1_mcu_firmware_studio.py
if not exist "%SCRIPT%" (
  echo Missing script: %SCRIPT%
  exit /b 1
)
where pyw >nul 2>nul
if %errorlevel%==0 (
  start "" pyw -3 "%SCRIPT%"
  exit /b 0
)
py -3 "%SCRIPT%"
