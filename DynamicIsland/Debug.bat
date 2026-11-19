@echo off
chcp 65001 >nul
cd /d "%~dp0"
echo Запускаю Dynamic Island с видимой консолью. Лог: %LOCALAPPDATA%\DynamicIsland\island.log
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0DynamicIsland.ps1" -Console
echo.
echo Остров закрыт. Если была ошибка - она выше и в файле лога.
pause
