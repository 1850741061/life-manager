@echo off
cd H:\claude
git add -A
git commit -m "fix: improve task creation UX and fix help button

- Auto-select current project/group in task creation dropdown
- Don't hide input form when switching groups if it's already visible
- Replace project color indicator with icon (fa-project-diagram)
- Add null check for helpBtn to prevent errors
- Update input form visibility logic to be less intrusive"
git push origin main
pause
