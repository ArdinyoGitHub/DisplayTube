@echo off
rem Eski Weylus tabanli yol (yedek). Asil baslatici: DisplayTube.bat. Kablo takip modu acik: telefonu cikarip takinca yeniden baglanir.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0DisplayTube-weylus.ps1" -Watch %*
pause
