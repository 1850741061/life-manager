@echo off
echo ========================================
echo Todo Windows Setup Builder
echo ========================================
echo.
echo Current directory: %CD%
echo.
echo Starting build process...
echo.

node_modules\.bin\electron-builder.cmd --win --publish never

echo.
if errorlevel 1 (
    echo ========================================
    echo Build FAILED! Check errors above.
    echo ========================================
) else (
    echo ========================================
    echo Build SUCCESS!
    echo ========================================
    echo.
    echo Setup files are in the dist folder:
    dir /b dist\*.exe
    echo.
    echo Opening dist folder...
    start explorer.exe dist
)
echo.
pause
