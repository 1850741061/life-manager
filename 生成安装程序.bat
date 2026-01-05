@echo off
chcp 65001
echo ========================================
echo 正在构建 Todo 应用的 Windows 安装程序...
echo ========================================
echo.

H:
cd \claude

echo 正在检查依赖...
if not exist "node_modules\" (
    echo 正在安装依赖...
    call npm install
    echo.
)

echo 正在构建安装程序...
call npm run build:win

echo.
echo ========================================
echo 构建完成！
echo 安装程序位于: H:\claude\dist\
echo ========================================
echo.

explorer H:\claude\dist\

pause
