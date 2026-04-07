@echo off
REM =====================================
REM Setup Common\CopyBus under current dir
REM =====================================

REM %~dp0 = directory of this .bat
set BASE_DIR=%~dp0

REM Remove trailing backslash
if "%BASE_DIR:~-1%"=="\" set BASE_DIR=%BASE_DIR:~0,-1%

set COMMON_DIR=%BASE_DIR%\Common
set COPYBUS_DIR=%COMMON_DIR%\CopyBus

echo [INFO] Base directory:
echo %BASE_DIR%
echo.

REM Create Common folder
if not exist "%COMMON_DIR%" (
    echo [INFO] Creating Common folder...
    mkdir "%COMMON_DIR%"
) else (
    echo [INFO] Common folder already exists.
)

REM Create CopyBus folder
if not exist "%COPYBUS_DIR%" (
    echo [INFO] Creating CopyBus folder...
    mkdir "%COPYBUS_DIR%"
) else (
    echo [INFO] CopyBus folder already exists.
)

echo.
echo [DONE] Common\CopyBus setup completed.
pause
