const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const vm = require('node:vm');

function emptyState() {
  return {
    todos: [], groups: [], transactions: [], templates: [], archivedTodos: [],
    habits: [], habitRecords: {}, projects: [],
    milktea: { records: [], settings: { weeklyLimit: 2, monthlyLimit: 8 } },
    coffee: { records: [], settings: { weeklyLimit: 3, monthlyLimit: 12 } },
    dailyPlans: [], ideas: [], ideaTags: [], deletedIds: [], focusSessions: []
  };
}

function createHarness() {
  const values = new Map();
  const context = {
    console: { log() {}, warn() {}, error() {} },
    currentUser: { id: 'roundtrip-user' },
    getThemePrefs: () => ({}),
    localStorage: {
      getItem: key => values.has(key) ? values.get(key) : null,
      setItem: (key, value) => values.set(key, String(value)),
      removeItem: key => values.delete(key)
    },
    require,
    ensureSyncArray: value => Array.isArray(value) ? value : [],
    ensureSyncObject: value => value && typeof value === 'object' && !Array.isArray(value) ? value : {},
    state: emptyState(),
    syncIdeaTags() {
      context.state.ideaTags = [...new Set(
        context.state.ideas.flatMap(idea => Array.isArray(idea.tags) ? idea.tags : [])
      )];
    },
    window: {}
  };
  context.baseSave = () => {
    values.set('todos', JSON.stringify(context.state.todos));
    values.set('local_data_revision_v1', JSON.stringify({ test: true }));
  };
  vm.createContext(context);
  const html = fs.readFileSync(path.join(__dirname, '..', 'index.html'), 'utf8');
  const sanitizerStart = html.indexOf('const ACTIVE_SYNC_MARKUP_PATTERN');
  const sanitizerEnd = html.indexOf('function exportWidgetData', sanitizerStart);
  vm.runInContext(html.slice(sanitizerStart, sanitizerEnd), context);
  const coreStart = html.indexOf('function normalizeFinanceTransactionId');
  const coreEnd = html.indexOf('// 登录时的同步：以云端数据为准', coreStart);
  vm.runInContext(html.slice(coreStart, coreEnd), context);
  const helperStart = html.indexOf('function canonicalSyncJson', coreEnd);
  const helperEnd = html.indexOf('async function syncToCloud', helperStart);
  vm.runInContext(html.slice(helperStart, helperEnd), context);
  return context;
}

function createBaseSaveHarness() {
  const values = new Map();
  const context = {
    console: { log() {}, warn() {}, error() {} },
    currentUser: { id: 'roundtrip-user' },
    localStorage: {
      getItem: key => values.has(key) ? values.get(key) : null,
      setItem: (key, value) => values.set(key, String(value)),
      removeItem: key => values.delete(key)
    },
    state: emptyState(),
    ensureSyncArray: value => Array.isArray(value) ? value : [],
    ensureSyncObject: value => value && typeof value === 'object' && !Array.isArray(value) ? value : {},
    neutralizeSyncStateInPlace() {},
    normalizeDrinkRecord: record => record,
    syncIdeaTags() {},
    compactSyncTombstones: value => value,
    dedupeFinanceTransactions: value => value,
    exportWidgetData() {},
    CROSS_TAB_BUSINESS_REVISION_KEY: 'local_data_revision_v1',
    CROSS_TAB_INSTANCE_ID: 'test-tab',
    crossTabRevisionCounter: 0,
    window: {}
  };
  vm.createContext(context);
  const html = fs.readFileSync(path.join(__dirname, '..', 'index.html'), 'utf8');
  const start = html.indexOf('function readLatestLocalDataRevision');
  const end = html.indexOf('function animateValue', start);
  vm.runInContext(html.slice(start, end), context);
  return context;
}

function plain(value) {
  return JSON.parse(JSON.stringify(value));
}

test('three-way merge combines changes to different fields', () => {
  const context = createHarness();
  context.baseValue = { id: '1', text: 'base', completed: false };
  context.localValue = { id: '1', text: 'local', completed: false };
  context.remoteValue = { id: '1', text: 'base', completed: true };
  const merged = vm.runInContext('mergeSyncValue(localValue, remoteValue, baseValue)', context);
  assert.deepEqual(plain(merged), { id: '1', text: 'local', completed: true });
});

test('custom drink limits beat untimestamped defaults and unknown settings survive', () => {
  const context = createHarness();
  context.defaults = { weeklyLimit: 2, monthlyLimit: 8 };
  context.custom = { weeklyLimit: 1, monthlyLimit: 3, dailyCaffeineLimitMg: 350 };
  const defaultFirst = vm.runInContext(
    "mergeDrinkSettings(defaults, custom, {}, 'milktea')",
    context
  );
  const customFirst = vm.runInContext(
    "mergeDrinkSettings(custom, defaults, {}, 'milktea')",
    context
  );
  assert.deepEqual(plain(defaultFirst), plain(customFirst));
  assert.deepEqual(plain(defaultFirst), {
    weeklyLimit: 1,
    monthlyLimit: 3,
    dailyCaffeineLimitMg: 350
  });
});

test('drink limits resolve defaults per field and preserve explicit caffeine settings', () => {
  const context = createHarness();
  context.partialLocal = {
    weeklyLimit: 1,
    monthlyLimit: 8,
    dailyCaffeineLimitMg: 350
  };
  context.partialCloud = {
    weeklyLimit: 2,
    monthlyLimit: 3,
    dailyCaffeineLimitMg: 400,
    extraLimit: 7
  };
  const merged = vm.runInContext(
    "mergeDrinkSettings(partialLocal, partialCloud, {}, 'milktea')",
    context
  );
  assert.deepEqual(plain(merged), {
    weeklyLimit: 1,
    monthlyLimit: 3,
    dailyCaffeineLimitMg: 400,
    extraLimit: 7
  });
});

test('accepted cloud payload followed by another sync is a no-op', () => {
  const context = createHarness();
  context.state.transactions = [{
    id: '42', type: 'expense', amount: 12.5, category: '餐饮',
    date: '2026-07-18', note: 'cloud',
    createdAt: '2026-07-18T01:00:00.000Z',
    updatedAt: '2026-07-18T01:00:00.000Z'
  }];
  context.cloudRow = vm.runInContext('buildCloudPayloadForSync([], currentUser.id)', context);

  context.state = emptyState();
  vm.runInContext('mergeCloudRowIntoState(cloudRow, {}, Date.parse("2026-07-18T02:00:00.000Z"))', context);
  context.nextPayload = vm.runInContext(
    'buildCloudPayloadForSync(state.deletedIds, currentUser.id)',
    context
  );

  assert.equal(vm.runInContext('cloudPayloadHasChanges(nextPayload, cloudRow)', context), false);
  context.secondPayload = vm.runInContext(
    'buildCloudPayloadForSync(state.deletedIds, currentUser.id)',
    context
  );
  assert.equal(vm.runInContext('cloudPayloadHasChanges(secondPayload, cloudRow)', context), false);
});

test('legacy numeric tombstones are typed for matches and string-preserved when unmatched', () => {
  const context = createHarness();
  context.cloudRow = {
    todos: [{
      id: 123, text: 'stale', completed: false, subtasks: [],
      createdAt: '2026-07-18T00:00:00.000Z',
      updatedAt: '2026-07-18T00:00:00.000Z'
    }],
    deletedids: [123]
  };
  vm.runInContext('mergeCloudRowIntoState(cloudRow, {}, Date.parse("2026-07-18T02:00:00.000Z"))', context);
  assert.deepEqual(plain(context.state.todos), []);
  assert.deepEqual(plain(context.state.deletedIds), ['todo:123']);

  context.state = emptyState();
  context.cloudRow = { deletedids: [999] };
  vm.runInContext('mergeCloudRowIntoState(cloudRow, {}, Date.parse("2026-07-18T02:00:00.000Z"))', context);
  assert.deepEqual(plain(context.state.deletedIds), ['999']);
  context.payload = vm.runInContext(
    'buildCloudPayloadForSync(state.deletedIds, currentUser.id)',
    context
  );
  assert.deepEqual(plain(context.payload.deletedids), ['999']);
});

test('accepted entity tombstones stay monotonic across stale clients', () => {
  const context = createHarness();
  context.localIds = [];
  context.cloudIds = [];
  context.baseIds = ['todo:accepted-delete'];
  const merged = vm.runInContext(
    'mergeDeletedIdsThreeWay(localIds, cloudIds, baseIds, {})',
    context
  );
  assert.deepEqual(plain(merged), ['todo:accepted-delete']);
});

test('cross-tab local snapshots merge additions and advance a complete-snapshot marker', () => {
  const context = createHarness();
  context.localTodo = {
    id: 'local-tab-todo', text: '本标签页', completed: false, subtasks: [],
    createdAt: '2026-07-29T01:00:00.000Z',
    updatedAt: '2026-07-29T01:00:00.000Z'
  };
  context.otherTodo = {
    id: 'other-tab-todo', text: '另一标签页', completed: false, subtasks: [],
    createdAt: '2026-07-29T01:01:00.000Z',
    updatedAt: '2026-07-29T01:01:00.000Z'
  };
  context.state.todos = [context.localTodo];
  context.localStorage.setItem('data_owner_user_id', context.currentUser.id);
  context.localStorage.setItem('todos', JSON.stringify([context.otherTodo]));

  assert.equal(
    vm.runInContext('reconcileCrossTabBusinessCache()', context),
    true
  );
  assert.deepEqual(
    plain(context.state.todos.map(todo => todo.id).sort()),
    ['local-tab-todo', 'other-tab-todo']
  );
  assert.ok(context.localStorage.getItem('local_data_revision_v1'));
});

test('base save rejects a stale owner and publishes an owned complete-snapshot marker', () => {
  const context = createBaseSaveHarness();
  context.state.todos = [{
    id: 'owned-todo', text: '账号隔离', completed: false, subtasks: []
  }];
  context.localStorage.setItem('data_owner_user_id', 'another-user');

  assert.equal(vm.runInContext('baseSave()', context), false);
  assert.equal(context.localStorage.getItem('todos'), null);

  context.localStorage.setItem('data_owner_user_id', context.currentUser.id);
  assert.equal(vm.runInContext('baseSave()', context), true);
  assert.deepEqual(JSON.parse(context.localStorage.getItem('todos')), context.state.todos);
  assert.equal(
    context.localStorage.getItem('storage_metadata_cleanup_v1'),
    'complete'
  );
  const revision = JSON.parse(context.localStorage.getItem('local_data_revision_v1'));
  assert.equal(revision.ownerId, context.currentUser.id);
  assert.equal(revision.operation, 'save');
  assert.equal(revision.tabId, 'test-tab');

  context.localStorage.setItem('data_owner_user_id', context.currentUser.id);
  assert.equal(
    vm.runInContext("signalCrossTabOwnershipBoundary(null, 'logout')", context),
    true
  );
  assert.equal(vm.runInContext('baseSave()', context), false);
});

test('account switch and logout publish boundaries around ownership changes', () => {
  const html = fs.readFileSync(path.join(__dirname, '..', 'index.html'), 'utf8');
  const isolateSource = html.slice(
    html.indexOf('function isolateLocalDataForUser'),
    html.indexOf('// --- 初始化 ---')
  );
  assert.ok(
    isolateSource.indexOf("signalCrossTabOwnershipBoundary(nextUserId, 'switch')")
      < isolateSource.indexOf("localStorage.setItem('data_owner_user_id', nextUserId)")
  );

  const signOutSource = html.slice(
    html.indexOf('async function signOut'),
    html.indexOf('function canonicalSyncJson', html.indexOf('async function signOut'))
  );
  assert.ok(
    signOutSource.indexOf('/auth/v1/logout?scope=local')
      < signOutSource.indexOf("signalCrossTabOwnershipBoundary(null, 'logout')")
  );
  assert.ok(
    signOutSource.indexOf("signalCrossTabOwnershipBoundary(null, 'logout')")
      < signOutSource.indexOf("localStorage.removeItem('data_owner_user_id')")
  );
  assert.match(signOutSource, /backupAccountScopedLocalData\(signingOutUserId\)/);
  assert.match(signOutSource, /resetAccountScopedState\(\)/);
  assert.ok(
    signOutSource.indexOf("localStorage.removeItem('data_owner_user_id')")
      < signOutSource.indexOf('baseSave(null)')
  );
});

test('all embedded application and widget scripts parse', () => {
  for (const file of ['index.html', path.join('widget', 'widget.html')]) {
    const html = fs.readFileSync(path.join(__dirname, '..', file), 'utf8');
    for (const match of html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/gi)) {
      if (/\bsrc\s*=/.test(match[1]) || /type\s*=\s*["']application\/(json|ld\+json)/i.test(match[1])) continue;
      if (match[2].trim()) new vm.Script(match[2], { filename: file });
    }
  }
});

test('Electron renderers are sandboxed and remote sync dependencies are pinned', () => {
  const root = path.join(__dirname, '..');
  const main = fs.readFileSync(path.join(root, 'main.js'), 'utf8');
  const index = fs.readFileSync(path.join(root, 'index.html'), 'utf8');
  const widget = fs.readFileSync(path.join(root, 'widget', 'widget.html'), 'utf8');
  const packageJson = JSON.parse(fs.readFileSync(path.join(root, 'package.json'), 'utf8'));

  assert.equal((main.match(/nodeIntegration:\s*false/g) || []).length, 2);
  assert.equal((main.match(/contextIsolation:\s*true/g) || []).length, 2);
  assert.equal((main.match(/sandbox:\s*true/g) || []).length, 2);
  assert.match(main, /containsSensitiveWidgetKey/);
  assert.match(main, /requestSingleInstanceLock\(\)/);
  assert.match(main, /app\.on\('second-instance',[\s\S]*focusOrCreateMainWindow\(\)/);
  assert.match(main, /function ensureMainWindow\(\)[\s\S]*!mainWindow \|\| mainWindow\.isDestroyed\(\)[\s\S]*createWindow\(\)/);
  assert.match(main, /function focusOrCreateMainWindow\(\)[\s\S]*!app\.isReady\(\)[\s\S]*app\.whenReady\(\)[\s\S]*ensureMainWindow\(\)/);
  assert.match(main, /function createWindow\(\)[\s\S]*mainWindow && !mainWindow\.isDestroyed\(\)[\s\S]*return mainWindow/);
  assert.match(main, /setWindowOpenHandler\(\(\) => \(\{ action: 'deny' \}\)\)/);
  assert.ok(fs.existsSync(path.join(root, 'preload.js')));
  assert.ok(fs.existsSync(path.join(root, 'widget', 'preload.js')));
  assert.ok(packageJson.build.files.includes('preload.js'));
  assert.ok(packageJson.build.files.includes('widget/**/*'));

  for (const [name, renderer] of [['index.html', index], ['widget.html', widget]]) {
    assert.doesNotMatch(renderer, /\brequire\s*\(/, `${name} must not access Node directly`);
    assert.doesNotMatch(renderer, /\bprocess\.env\b/, `${name} must not access the environment`);
  }
  assert.match(index, /chart\.js@4\.4\.0[^>]+integrity="sha384-e6nUZLBkQ86NJ6TVVKAeSaK8jWa3NhkYWZFomE39AvDbQWeie9PlQqM3pmYW5d1g"/);
  assert.match(index, /supabase-js@2\.110\.7[^>]+integrity="sha384-BmlQlKlDvXvKoxkn5OQuUo\/aJQCTXeB\+Kls6EccBmG4Kf8AXvp89RtO9MtPxP\/r5"/);
  assert.doesNotMatch(index.match(/Content-Security-Policy" content="([^"]+)"/)?.[1] || '', /localhost|127\.0\.0\.1/);
  const widgetCsp = widget.match(/Content-Security-Policy" content="([^"]+)"/)?.[1] || '';
  assert.match(widgetCsp, /connect-src 'self'/);
  assert.doesNotMatch(widgetCsp, /supabase/i);
});

test('Realtime SDK cannot run a competing auth refresh loop', () => {
  const index = fs.readFileSync(path.join(__dirname, '..', 'index.html'), 'utf8');
  assert.match(index, /persistSession:\s*false/);
  assert.match(index, /autoRefreshToken:\s*false/);
  assert.match(index, /detectSessionInUrl:\s*false/);
  assert.match(index, /SYNC_REQUEST_TIMEOUT_MS\s*=\s*15000/);
  assert.match(index, /callerSignal/);
  assert.match(index, /select=\$\{SYNC_RETURN_COLUMNS\}/);
});

test('browser storage and auth tokens are application-scoped', () => {
  const index = fs.readFileSync(path.join(__dirname, '..', 'index.html'), 'utf8');
  assert.match(index, /PROLIFE_STORAGE_PREFIX\s*=\s*'prolife_claude::'/);
  assert.match(index, /legacyStorageKeysNotToCopy[\s\S]*'access_token'[\s\S]*'refresh_token'[\s\S]*'sync_base_snapshots_v2'[\s\S]*'data_owner_user_id'[\s\S]*'saved_accounts'[\s\S]*'pendingLogoutBackup'/);
  assert.match(index, /rawLocalStorage\.getItem\(`\$\{PROLIFE_STORAGE_PREFIX\}/);
  assert.match(index, /local_data_revision_v1/);
});

test('legacy renderer neutralizes active markup and unsafe attribute values', () => {
  const source = fs.readFileSync(path.join(__dirname, '..', 'index.html'), 'utf8');
  const start = source.indexOf('const ACTIVE_SYNC_MARKUP_PATTERN');
  const end = source.indexOf('function exportWidgetData', start);
  const context = { state: {
    todos: [{ id: "bad');alert(1)//", text: '<img src=x onerror=alert(1)>', projectColor: 'red;position:fixed', icon: 'x" onclick="alert(1)' }],
    ideas: [{ id: 'safe-id', content: '2 < 3' }]
  } };
  vm.createContext(context);
  vm.runInContext(source.slice(start, end), context);
  vm.runInContext('neutralizeSyncStateInPlace()', context);

  assert.equal(context.state.todos[0].text, '＜img src=x onerror=alert(1)＞');
  assert.match(context.state.todos[0].id, /^[a-z0-9_.:-]+$/i);
  assert.equal(context.state.todos[0].projectColor, '#6b7280');
  assert.equal(context.state.todos[0].icon, 'circle');
  assert.equal(context.state.ideas[0].content, '2 < 3');
});

test('legacy habit tombstones and nested habit-record keys use the same sanitized id', () => {
  const context = createHarness();
  context.unsafeHabitId = '中文 habit';
  context.rawState = {
    habits: [{ id: context.unsafeHabitId, name: '兼容习惯' }],
    habitRecords: { [context.unsafeHabitId]: { '2026-07-29': 100 } },
    deletedIds: [
      `habit-record:${context.unsafeHabitId}:2026-07-28`,
      `habit-record-delete:${context.unsafeHabitId}:2026-07-29:200`
    ]
  };
  const sanitized = vm.runInContext(
    'neutralizeActiveSyncMarkup(rawState, "")',
    context
  );
  const safeHabitId = vm.runInContext(
    'encodeUnsafeSyncId(unsafeHabitId)',
    context
  );

  assert.equal(safeHabitId, 'u_46d75b0f__u4e2d__u6587__u20_habit');
  assert.equal(vm.runInContext("encodeUnsafeSyncId('')", context), 'invalid_1yz14zp');
  assert.equal(sanitized.habits[0].id, safeHabitId);
  assert.deepEqual(plain(sanitized.habitRecords), {
    [safeHabitId]: { '2026-07-29': 100 }
  });
  assert.deepEqual(plain(sanitized.deletedIds), [
    `habit-record:${safeHabitId}:2026-07-28`,
    `habit-record-delete:${safeHabitId}:2026-07-29:200`
  ]);
  assert.notEqual(safeHabitId, '_u4e2d__u6587__u20_habit');
});
