@echo off
cd /d "%~dp0"
echo This deletes the local database and loads the demo accounts and sample course again.
set /p OK=Type YES to continue: 
if /i not "%OK%"=="YES" exit /b 0
if exist data rmdir /s /q data
call start.bat
