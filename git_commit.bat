@echo off
cd H:\claude
git add -A
git commit -m "feat: merge group/project selector, add project stats, implement smart task input form

- Merge group and project selectors into unified dropdown with divider and type labels
- Implement mutual exclusion between group and project highlighting
- Project tasks only show when project is selected, not in 'all tasks'
- Add independent statistics for projects (total, active, completion rate)
- Add smart task input form: auto-show when empty, fab button when has tasks
- Remove project filter bar and category radio buttons"
git push origin main
pause
