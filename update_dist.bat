@echo off
echo Updating dist files...
copy /Y "H:\claude\index.html" "H:\claude\dist\ProLife-win32-x64\resources\app\index.html"
copy /Y "H:\claude\manifest.json" "H:\claude\dist\ProLife-win32-x64\resources\app\manifest.json"
echo Update complete!
pause
