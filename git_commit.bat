@echo off
cd H:\claude
git add -A
git commit -m "fix: complete project/group integration and edit task bugs

- Add color to project icons in sidebar and selector
- Auto-expand form when switching to empty project/group
- Auto-switch form selector to current project/group
- Fix task labels showing NULL when adding to projects
- Fix edit modal to show correct project/group selection
- Fix saveEditTask to handle project/group mutual exclusion
- Prevent undefined errors when saving edited tasks
- Improve help button event binding"
git push origin main
pause
