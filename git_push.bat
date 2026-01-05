@echo off
cd H:\claude
git add -A
git commit -m "fix: preserve remembered account info after logout"
git push origin main
pause
