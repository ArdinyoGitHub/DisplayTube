@echo off
rem DisplayTube'u baslatir. Kablo takip modu acik: telefonu cikarip takinca yeniden baglanir.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0DisplayTube.ps1" -Watch %*
pause
