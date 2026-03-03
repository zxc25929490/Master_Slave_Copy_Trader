@echo off
setlocal EnableExtensions
chcp 65001 >nul

title CopyBus Junction Setup (Direct Path v3)

REM --- Admin check ---
net session >nul 2>&1
if not %errorlevel%==0 (
  echo [ERROR] Please run as Administrator.
  echo 右鍵此 .bat -> 以系統管理員執行
  pause
  exit /b 1
)

echo.
echo ==========================================
echo      CopyBus Junction Setup Tool (v3)
echo ==========================================
echo.

echo 請貼上 Slave 的 MQL4\Files 完整路徑：
echo 例：C:\Users\Administrator\AppData\Roaming\MetaQuotes\Terminal\XXXX\MQL4\Files
echo.

set "SLAVE_FILES_PATH="
set /p "SLAVE_FILES_PATH=Slave MQL4\Files Path: "

if "%SLAVE_FILES_PATH%"=="" (
  echo [ERROR] 路徑不能為空
  pause
  exit /b 1
)

REM --- Strip quotes if pasted with "..." ---
set "SLAVE_FILES_PATH=%SLAVE_FILES_PATH:"=%"

set "COMMON_PATH=%APPDATA%\MetaQuotes\Terminal\Common\Files\CopyBus"
set "SLAVE_COPYBUS_PATH=%SLAVE_FILES_PATH%\CopyBus"

echo.
echo ==========================================
echo Slave CopyBus Path:
echo %SLAVE_COPYBUS_PATH%
echo.
echo Master(Common) Path:
echo %COMMON_PATH%
echo ==========================================
echo.

REM --- Ensure common folder exists (NO parentheses block) ---
if not exist "%COMMON_PATH%" mkdir "%COMMON_PATH%"

REM --- Remove existing CopyBus (folder or junction) ---
if exist "%SLAVE_COPYBUS_PATH%" rmdir "%SLAVE_COPYBUS_PATH%"

echo [INFO] Creating Junction...
mklink /J "%SLAVE_COPYBUS_PATH%" "%COMMON_PATH%"

echo.
echo ==========================================
echo Done.
echo If you see "Junction created", it worked.
echo ==========================================
pause