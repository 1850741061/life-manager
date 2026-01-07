@echo off
cd H:\claude
git add -A
git commit -m "feat: add automatic token refresh to prevent sync failure"
git push origin main
pause
