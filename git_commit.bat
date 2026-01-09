@echo off
cd H:\claude
git add -A
git commit -m "fix: improve UX with unified FAB button and better task creation flow

- Remove duplicate FAB button, use existing mobile-fab for desktop too
- Change FAB behavior to toggle input form instead of hiding button
- Click to expand input form and scroll to it smoothly
- Remove 'All Tasks' option from selector, auto-select current group/project
- Increase task item padding and margin for better readability
- Fix: can now add tasks to projects correctly"
git push origin main
pause
