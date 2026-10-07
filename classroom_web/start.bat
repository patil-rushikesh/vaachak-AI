@echo off
cd /d "%~dp0"
echo Starting Vaachak Classroom...
if not exist .venv\Scripts\activate.bat (
  py -m venv .venv 2>nul || python -m venv .venv
)
if not exist .venv\Scripts\activate.bat (
  echo Could not create a Python environment. Install Python 3.10+ from python.org and try again.
  pause
  exit /b 1
)
call .venv\Scripts\activate.bat
pip install -q -r requirements.txt
if errorlevel 1 (
  echo Installing packages failed. Check your internet connection.
  pause
  exit /b 1
)
set SEED=
if not exist data\classroom.db set SEED=--seed
start "" cmd /c "timeout /t 4 >nul & start http://localhost:8000"
python run.py %SEED%
pause
