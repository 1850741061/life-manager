# ProLife 项目上下文

## 项目概述
- **名称**: ProLife 待办记账应用
- **类型**: Electron 桌面应用 + PWA 网页应用
- **功能**: 任务管理、记账、云同步

## GitHub 仓库
- **地址**: https://github.com/1850741061/life-manager
- **分支**: main
- **Pages**: https://1850741061.github.io/life-manager/

## Supabase 配置
- **项目 ID**: gcrdheovyzjywwyijjli
- **URL**: https://gcrdheovyzjywwyijjli.supabase.co
- **API Key (anon public)**:
  ```
  eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImdjcmRoZW92eXpqeXd3eWlqamxpIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjY1NzQxMDIsImV4cCI6MjA4MjE1MDEwMn0.7bhn24n_-HMPbN_IeTb6cZNrzH3-GFkKtxv0imkOSBM
  ```

### 数据库表结构
```sql
create table user_data (
  id uuid primary key references auth.users(id) on delete cascade,
  todos jsonb default '[]',
  transactions jsonb default '[]',
  groups jsonb default '[{"id":"default","name":"默认","color":"#3b82f6"}]',
  updated_at timestamptz default now()
);

alter table user_data enable row level security;

create policy "Users can view own data" on user_data
  for select using (auth.uid() = id);

create policy "Users can modify own data" on user_data
  for all using (auth.uid() = id);
```

## 文件结构
```
H:\claude\
├── index.html                          # 浏览器版本（已部署到 GitHub Pages）
├── manifest.json                        # PWA 配置
├── sw.js                                # Service Worker（缓存策略：网络优先）
├── vercel.json                          # Vercel 配置（未使用）
├── supabase/
│   └── config.toml                      # Supabase 本地配置
└── dist/ProLife-win32-x64/resources/app/
    └── index.html                      # 桌面版本（Electron 打包）
```

## 已实现功能
1. ✅ 子任务功能
2. ✅ 时间规划（几点到几点）
3. ✅ 日历任务详情视图
4. ✅ Pop 风格自定义下拉组件
5. ✅ PWA 支持（可安装到手机）
6. ✅ 云同步（Supabase + fetch API，无 SDK 依赖）
7. ✅ 合并同步逻辑（不覆盖本地数据）
8. ✅ 防抖云同步（2秒延迟，避免卡顿）

## 关键技术实现

### 云同步实现
- **不使用 Supabase SDK**（Electron 兼容性问题）
- **使用 fetch API** 直接调用 Supabase REST API
- **防抖机制**：停止操作 2 秒后才同步，避免卡顿
- **合并策略**：使用 ID 去重，不覆盖本地数据

### API 端点
```
登录: POST /auth/v1/token?grant_type=password
注册: POST /auth/v1/signup
获取数据: GET /rest/v1/user_data?id=eq.{user_id}
上传数据: POST /rest/v1/user_data (使用 Prefer: resolution=ignore-duplicates)
```

### 同步逻辑
```javascript
// 基础保存
function baseSave() {
    localStorage.setItem('todos', JSON.stringify(state.todos));
    localStorage.setItem('groups', JSON.stringify(state.groups));
    localStorage.setItem('transactions', JSON.stringify(state.transactions));
}

// 云同步（2秒防抖）
function save() {
    baseSave();  // 立即保存到本地
    if (currentUser) {
        setTimeout(() => syncToCloud(), 2000);  // 2秒后云同步
    }
}
```

## 最近修复的问题

### 1. 无限循环导致堆栈溢出
- **问题**: `syncDataOnLogin` → `save()` → `syncToCloud()` → 循环
- **解决**: 在 `syncDataOnLogin` 中直接调用 localStorage 操作

### 2. 数据覆盖问题
- **问题**: 云端空数据覆盖本地数据
- **解决**: 改为合并策略，使用 `mergeArrays()` 函数

### 3. UI 不更新问题
- **问题**: 原始 `save()` 函数引用了不存在的 `USE_CLOUD` 变量
- **解决**: 拆分为 `baseSave()` 和重写的 `save()` 函数

### 4. Service Worker 缓存问题
- **问题**: 缓存优先策略导致旧版本一直被使用
- **解决**: 改为网络优先策略，更新缓存版本为 `prolife-v2`

## 当前状态
- ✅ 浏览器版本：已部署到 GitHub Pages
- ✅ 桌面版本：本地打包
- ✅ 云同步：正常工作
- ⚠️ 需要测试：所有 CRUD 操作是否正常

## 已知待办
- [ ] 测试所有功能的完整性
- [ ] 考虑添加删除账号时清理云端数据
- [ ] 考虑添加数据导出/导入功能
- [ ] 可能需要添加同步冲突提示

## 提交记录
最近的关键提交：
- `6fae937` - Fix UI not updating after operations
- `f23284c` - Add debounce to reduce sync frequency
- `e2a9780` - Fix sync: merge data instead of overwriting
- `8b5fd7b` - Fix infinite loop in syncDataOnLogin

## 开发命令
```bash
cd /h/claude

# 查看状态
git status

# 提交更改
git add .
git commit -m "message"
git push origin main

# 本地预览浏览器版本
# 直接双击打开 H:\claude\index.html
```

## 联系方式
- 用户需要先注册账号并验证邮箱才能使用云同步
- 注册后会显示需要邮箱验证的提示

---
最后更新：2025-12-25
