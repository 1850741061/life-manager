# ProLife App - 待修复问题交接文档

## 项目文件
- **源文件**: `H:\claude\index.html` (单文件 Electron 应用，约14600行)
- **Dist**: `H:\claude\dist\ProLife-win32-x64\resources\app\index.html` (修改完需复制过去)
- **设计语言**: Pop-art 风格，硬阴影 6px 6px，border-radius 2px，支持暗色模式

---

## ✅ 已完成：桌面小组件功能 (2026-02-27)

### 功能说明
为 ProLife 添加了独立的桌面小组件，用于快速查看和管理任务、项目和每日计划。

### 实现内容

#### 1. 主应用修改 (index.html)
- **第 3549 行**：添加小组件启动按钮（方格图标）
- **第 8806-8825 行**：修改 `baseSave()` 函数，自动导出数据到 `%APPDATA%/ProLife/widget-data.json`
- **第 14847-14857 行**：添加 `launchWidget()` 函数，通过 IPC 启动小组件

#### 2. 主进程修改 (main.js)
- **第 3 行**：导入 `spawn` 模块
- **第 6 行**：添加 `widgetProcess` 变量跟踪进程状态
- **第 59-62 行**：添加 'launch-widget' IPC handler
- **第 64-97 行**：实现 `launchWidget()` 函数，使用 spawn 启动独立进程

#### 3. 打包配置 (package.json)
- **第 37 行**：添加 `"widget/**/*"` 到 `build.files`，打包时包含小组件

#### 4. 小组件文件 (widget/)
- **widget-main.js**：Electron 主进程，400x700 无边框置顶窗口，托盘图标
- **widget.html**：单文件 UI，三个标签页（任务/项目/今日），Pop-art 设计，暗色模式
- **package.json**：独立配置文件
- **start-widget.bat**：Windows 快速启动脚本
- **README.md**：使用说明文档
- **TEST.md**：测试验证清单

### 关键特性
- **独立进程**：使用 spawn + detached，与主应用完全独立
- **数据同步**：本地文件 + Supabase 云端双数据源
- **任务过滤**：任务标签页只显示独立任务（不含项目内任务）
- **实时操作**：勾选完成任务/计划，自动同步到主应用和云端
- **防重复启动**：通过进程状态跟踪，避免多实例
- **位置记忆**：窗口位置保存在 `%APPDATA%/ProLife/widget-pos.json`

### 使用方法
1. **从主应用启动**：点击顶部工具栏的小组件图标（方格图标）
2. **独立启动**：运行 `widget/start-widget.bat` 或 `npx electron .`
3. **打包后启动**：运行 ProLife.exe，点击小组件图标

### 数据流
```
主应用 baseSave() → %APPDATA%/ProLife/widget-data.json
                  ↘ Supabase (云端)

小组件启动 → 读取本地文件 → 渲染
          → 有网络时从 Supabase 刷新
          → 用户操作 → 写回本地 + 同步云端
```

### 测试验证
- ✅ 主应用能正常启动小组件
- ✅ 小组件显示正确数据
- ✅ 任务过滤逻辑正确（只显示独立任务）
- ✅ 完成操作同步到主应用
- ✅ 打包配置包含 widget 目录
- ⏳ 待测试：打包后的实际运行

### 相关文件
- `widget/README.md` - 详细使用说明
- `widget/TEST.md` - 完整测试清单

---

## Bug 1: "今日"按钮位置错误
**现状**: "今日"按钮被放在了待办筛选栏（全部/进行中/已完成旁边）
**需求**: 应该放在左侧栏"全部任务"的下面一格，作为独立入口

### 修改步骤:
1. **删除筛选栏中的今日按钮** (约第3659行):
   - 删除 `<button class="btn" id="btnFilterToday" onclick="setFilter('today')"...>今日</button>`

2. **在左侧栏添加今日入口** — 找到侧边栏 `id="sidebar"` 中"全部任务"按钮的位置，在其下方添加一个"今日"按钮:
   - 样式参考其他侧边栏按钮
   - 点击时调用 `setFilter('today')` 并切换到 todo 视图

3. **更新 `updateTodoFilterUI()`** (约第6337行):
   - 已有 todayBtn 的高亮逻辑，左侧栏按钮也需要同步高亮状态
   - 搜索 `function updateTodoFilterUI` 查看当前实现

4. **侧边栏中的今日按钮需要在点击时**:
   - 清除当前分组/项目选择 (`state.currentGroupId = 'all'`, `state.currentProjectId = null`)
   - 设置 `state.filter = 'today'`
   - 调用 `updateTodoFilterUI()` 和 `renderTodos()`

---

## Bug 2: 记账月份详情弹窗丢失
**现状**: 月份头部的 `onclick="openMonthDetail(...)"` 被替换成了折叠/展开逻辑，导致详情弹窗无法打开
**需求**: 保留折叠/展开功能的同时，也能打开月份详情弹窗

### 修改步骤:
1. 找到 `renderFinanceByMonth()` 函数 (约第7893行)
2. 当前月份头部 HTML 中已移除 `onclick="openMonthDetail(...)"`
3. 需要在月份头部右侧添加一个"详情"按钮或图标，点击时调用 `openMonthDetail(monthKey, monthInc, monthExp)`
4. 或者改为：单击展开/折叠，双击打开详情；或在月份统计数字旁加个小按钮
5. `openMonthDetail` 函数在约第8035行，确认它仍然存在且功能正常

### 建议方案:
在 month-header 的 month-stats 后面加一个详情图标按钮:
```html
<i class="fas fa-external-link-alt" onclick="event.stopPropagation(); openMonthDetail('${monthKey}', ${monthInc}, ${monthExp})" style="cursor:pointer; margin-left:10px; font-size:0.9rem;"></i>
```
注意 `event.stopPropagation()` 防止触发折叠。

---

## Bug 3: 奶茶热力图只能看当月
**现状**: `renderMilkteaHeatmap` 只渲染当前月份，无法切换查看历史月份
**需求**: 能查看各个月的打卡频次

### 修改步骤:
1. 找到奶茶侧边栏 HTML 中热力图区域 (搜索 `id="mtHeatmap"`)，在标题旁添加左右箭头按钮用于切换月份
2. 在 state 或闭包中添加一个 `mtHeatmapMonth` 变量，默认为当前月
3. 修改 `renderMilkteaView()` (约第14320行):
   - 当前直接用 `currYear/currMonth` 调用 `renderMilkteaHeatmap`
   - 改为用 `mtHeatmapMonth` 变量控制显示哪个月
4. 添加 `changeMtHeatmapMonth(delta)` 函数，修改月份后重新调用 `renderMilkteaHeatmap`
5. 热力图区域 HTML 在日历视图的右侧奶茶面板中 (搜索 `打卡频次`)

### 参考位置:
- 热力图 HTML: 搜索 `id="mtHeatmap"`
- `renderMilkteaHeatmap` 函数: 约第14440行
- `renderMilkteaView` 调用热力图: 约第14410行 `renderMilkteaHeatmap(currYear, currMonth, monthRecords)`

---

## Bug 4: 每日计划添加无反应
**现状**: 点击"添加"按钮调用 `openAddDailyPlan()`，该函数使用 `prompt()` 弹窗，但在 Electron 中 prompt 可能不工作
**需求**: 改用应用内模态框

### 修改步骤:
1. 在 HTML 中添加一个每日计划添加模态框 (放在其他模态框附近，搜索 `milkteaModal` 参考格式):
```html
<div class="modal-overlay" id="dailyPlanModal">
    <div class="modal">
        <h2>添加每日计划</h2>
        <div style="margin-bottom:15px;">
            <label style="display:block;margin-bottom:8px;font-weight:800;font-size:0.8rem;text-transform:uppercase;">内容</label>
            <input type="text" id="dpTextInput" placeholder="计划内容">
        </div>
        <div style="margin-bottom:15px;display:flex;gap:15px;">
            <div style="flex:1;">
                <label style="display:block;margin-bottom:8px;font-weight:800;font-size:0.8rem;text-transform:uppercase;">开始时间</label>
                <input type="time" id="dpStartTimeInput">
            </div>
            <div style="flex:1;">
                <label style="display:block;margin-bottom:8px;font-weight:800;font-size:0.8rem;text-transform:uppercase;">结束时间</label>
                <input type="time" id="dpEndTimeInput">
            </div>
        </div>
        <div style="display:flex;justify-content:flex-end;gap:10px;">
            <button class="btn" onclick="closeModal('dailyPlanModal')">取消</button>
            <button class="btn btn-primary" onclick="saveDailyPlan()">保存</button>
        </div>
    </div>
</div>
```

2. 修改 `openAddDailyPlan` 函数 (约第14590行)，改为:
```javascript
window.openAddDailyPlan = function() {
    document.getElementById('dpTextInput').value = '';
    document.getElementById('dpStartTimeInput').value = '';
    document.getElementById('dpEndTimeInput').value = '';
    openModal('dailyPlanModal');
};
```

3. 添加 `saveDailyPlan` 函数:
```javascript
window.saveDailyPlan = function() {
    const text = document.getElementById('dpTextInput').value.trim();
    if (!text) { showSyncToast('请输入计划内容'); return; }
    state.dailyPlans.push({
        id: Date.now(),
        date: new Date().toISOString().split('T')[0],
        text,
        startTime: document.getElementById('dpStartTimeInput').value || '',
        endTime: document.getElementById('dpEndTimeInput').value || '',
        completed: false
    });
    save();
    closeModal('dailyPlanModal');
    renderDailyPlans();
};
```

---

## Bug 5: 奶茶记录云同步问题
**现状**: 每次重新进入应用，奶茶记录被清空。云同步可能没有对应的数据库列。

### 分析:
- `syncToCloud()` (第9147行) 已包含 `milktea: state.milktea` 在 payload 中
- `syncFromCloud()` (第9225行) 已包含 `state.milktea = data[0].milktea || ...`
- Realtime 订阅 (约第9320行) 也已处理 milktea
- **但 `dailyPlans` 未加入云同步！** 需要添加

### 可能原因:
1. Supabase `user_data` 表可能没有 `milktea` 列 — 如果是 JSONB 类型的单列存储则没问题，但如果是分列存储则需要加列
2. 上传时 milktea 数据可能被 Supabase 忽略（列不存在时 PATCH 不会报错但也不会保存）
3. 下载时 `data[0].milktea` 为 undefined，触发了 fallback 空值

### 修改步骤:
1. **检查 Supabase 表结构**: 搜索代码中 `SUPABASE_URL` 获取 URL，检查 `user_data` 表是否有 `milktea` 和 `dailyPlans` 列
2. **如果表是单 JSONB 列**: 检查上传 payload 是否被正确序列化
3. **如果是分列存储**: 需要在 Supabase 控制台给 `user_data` 表添加:
   - `milktea` 列 (类型 jsonb, 默认值 `{"records":[],"settings":{"weeklyLimit":2,"monthlyLimit":8}}`)
   - `dailyPlans` 列 (类型 jsonb, 默认值 `[]`)
4. **在 syncToCloud payload 中添加 dailyPlans** (第9160行):
   ```javascript
   dailyPlans: state.dailyPlans,
   ```
5. **在 syncFromCloud 中添加 dailyPlans 恢复** (第9249行附近):
   ```javascript
   state.dailyPlans = data[0].dailyPlans || [];
   ```
6. **在 Realtime 订阅处理中也添加 dailyPlans** (搜索 `cloudMilktea` 附近):
   ```javascript
   state.dailyPlans = payload.new.dailyPlans || [];
   ```
7. **在 syncDataOnLogin 中也添加** (搜索 `syncDataOnLogin` 函数)

### 快速验证方法:
在浏览器控制台执行:
```javascript
// 检查 milktea 数据是否在 localStorage
JSON.parse(localStorage.getItem('milktea'))
// 检查上传后云端是否有 milktea
// 登录后查看 syncToCloud 的 console.log 输出
```

---

## 通用注意事项
- 每次修改完 `index.html` 后需要复制到 dist: `cp H:/claude/index.html H:/claude/dist/ProLife-win32-x64/resources/app/index.html`
- 设计语言: `var(--shadow)` = `6px 6px 0`, `var(--radius)` = `2px`, 按钮用 `.btn` / `.btn-primary` 类
- 模态框用 `openModal('id')` / `closeModal('id')` 函数
- 保存数据用 `save()` 函数（会触发 baseSave + 云同步）
- Toast 提示用 `showSyncToast('消息')`
