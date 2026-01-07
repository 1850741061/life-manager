@echo off
cd H:\claude
git add -A
git commit -m "fix: improve token refresh with better error handling and logging"
git push origin main
pause
