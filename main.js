const { app, BrowserWindow, Menu, Tray, nativeImage, ipcMain, screen } = require('electron');
const path = require('path');
const fs = require('fs');

let mainWindow;
let widgetWindow = null;
let widgetTray = null;
let mainTray = null;
let isQuitting = false;

const LEGACY_SHARED_DIR = path.join(process.env.APPDATA || '', 'ProLife');
const APP_AUX_DIR = path.join(process.env.APPDATA || '', 'ProLife-Claude');
const SETTINGS_FILE = path.join(APP_AUX_DIR, 'settings.json');
const WIDGET_DATA_FILE = path.join(APP_AUX_DIR, 'widget-data.json');
const MAX_WIDGET_DATA_BYTES = 20 * 1024 * 1024;

function isTrustedRenderer(event) {
    const sender = event?.sender;
    return !!sender && (
        (mainWindow && !mainWindow.isDestroyed() && sender === mainWindow.webContents)
        || (widgetWindow && !widgetWindow.isDestroyed() && sender === widgetWindow.webContents)
    );
}

function containsSensitiveWidgetKey(value, seen = new Set()) {
    if (!value || typeof value !== 'object' || seen.has(value)) return false;
    seen.add(value);
    for (const [key, nested] of Object.entries(value)) {
        if (/^(auth|session|access_?token|refresh_?token|authorization|apikey|supabase_?(anon_?)?key)$/i.test(key)) {
            return true;
        }
        if (containsSensitiveWidgetKey(nested, seen)) return true;
    }
    return false;
}

function readWidgetDataText() {
    try {
        if (!fs.existsSync(WIDGET_DATA_FILE)) return null;
        const value = fs.readFileSync(WIDGET_DATA_FILE, 'utf8');
        if (Buffer.byteLength(value, 'utf8') > MAX_WIDGET_DATA_BYTES) return null;
        JSON.parse(value);
        return value;
    } catch (error) {
        console.warn('[Widget Data] 读取失败:', error);
        return null;
    }
}

function writeWidgetDataText(input) {
    try {
        const parsed = typeof input === 'string' ? JSON.parse(input) : input;
        if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
            throw new TypeError('widget data must be an object');
        }
        if (containsSensitiveWidgetKey(parsed)) {
            throw new TypeError('widget data must not contain credentials');
        }
        const serialized = JSON.stringify(parsed);
        if (Buffer.byteLength(serialized, 'utf8') > MAX_WIDGET_DATA_BYTES) {
            throw new RangeError('widget data is too large');
        }
        fs.mkdirSync(APP_AUX_DIR, { recursive: true });
        const temporaryFile = `${WIDGET_DATA_FILE}.tmp`;
        const backupFile = `${WIDGET_DATA_FILE}.bak`;
        fs.writeFileSync(temporaryFile, serialized, { encoding: 'utf8', mode: 0o600 });
        if (fs.existsSync(backupFile)) fs.unlinkSync(backupFile);
        if (fs.existsSync(WIDGET_DATA_FILE)) fs.renameSync(WIDGET_DATA_FILE, backupFile);
        try {
            fs.renameSync(temporaryFile, WIDGET_DATA_FILE);
            if (fs.existsSync(backupFile)) fs.unlinkSync(backupFile);
        } catch (error) {
            if (!fs.existsSync(WIDGET_DATA_FILE) && fs.existsSync(backupFile)) {
                fs.renameSync(backupFile, WIDGET_DATA_FILE);
            }
            throw error;
        }
        return { ok: true };
    } catch (error) {
        console.warn('[Widget Data] 写入失败:', error);
        return { ok: false, error: String(error?.message || error) };
    }
}

function secureWindow(window) {
    window.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
    window.webContents.on('will-navigate', (event, url) => {
        if (url !== window.webContents.getURL()) event.preventDefault();
    });
    window.webContents.on('will-attach-webview', event => event.preventDefault());
}

function migrateNonSensitiveAuxFiles() {
    try {
        if (!fs.existsSync(APP_AUX_DIR)) fs.mkdirSync(APP_AUX_DIR, { recursive: true });
        for (const name of ['settings.json', 'widget-pos.json']) {
            const source = path.join(LEGACY_SHARED_DIR, name);
            const target = path.join(APP_AUX_DIR, name);
            if (fs.existsSync(source) && !fs.existsSync(target)) fs.copyFileSync(source, target);
        }
    } catch (error) {
        console.warn('[migration] 无法迁移非敏感设置文件:', error);
    }
}

migrateNonSensitiveAuxFiles();

function readSettings() {
    try {
        const fs = require('fs');
        if (fs.existsSync(SETTINGS_FILE)) {
            return JSON.parse(fs.readFileSync(SETTINGS_FILE, 'utf-8'));
        }
    } catch(e) {}
    return { minimizeToTray: undefined, widgetBlurOpacity: 0.94 };
}

function writeSettings(settings) {
    try {
        const fs = require('fs');
        const dir = path.dirname(SETTINGS_FILE);
        if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
        fs.writeFileSync(SETTINGS_FILE, JSON.stringify(settings));
    } catch(e) {}
}
const WIDGET_WIDTH = 400;
const WIDGET_HEIGHT = 700;
const WIDGET_REVEAL_MARGIN = 24;

function getDefaultWidgetPosition(width = WIDGET_WIDTH, height = WIDGET_HEIGHT) {
    const area = screen.getPrimaryDisplay().workArea;
    return {
        x: Math.round(area.x + area.width - width - WIDGET_REVEAL_MARGIN),
        y: Math.round(area.y + WIDGET_REVEAL_MARGIN)
    };
}

function isWidgetPositionVisible(x, y, width, height) {
    return screen.getAllDisplays().some(display => {
        const area = display.workArea;
        const visibleWidth = Math.min(x + width, area.x + area.width) - Math.max(x, area.x);
        const visibleHeight = Math.min(y + height, area.y + area.height) - Math.max(y, area.y);
        return visibleWidth >= Math.min(160, width * 0.45) && visibleHeight >= Math.min(160, height * 0.35);
    });
}

function getSafeWidgetPosition(x, y, width = WIDGET_WIDTH, height = WIDGET_HEIGHT) {
    const fallback = getDefaultWidgetPosition(width, height);
    if (!Number.isFinite(x) || !Number.isFinite(y)) {
        return fallback;
    }
    if (isWidgetPositionVisible(x, y, width, height)) {
        return { x, y };
    }

    const nearestDisplay = screen.getDisplayNearestPoint({ x, y }) || screen.getPrimaryDisplay();
    const area = nearestDisplay.workArea;
    return {
        x: Math.max(area.x, Math.min(x, area.x + area.width - width)),
        y: Math.max(area.y, Math.min(y, area.y + area.height - height))
    };
}

function revealWidgetWindow({ focus = true } = {}) {
    if (!widgetWindow || widgetWindow.isDestroyed()) return;

    if (widgetWindow.isMinimized()) {
        widgetWindow.restore();
    }

    const [width, height] = widgetWindow.getSize();
    const [currentX, currentY] = widgetWindow.getPosition();
    const safePos = getSafeWidgetPosition(currentX, currentY, width, height);

    widgetWindow.setBounds({ x: safePos.x, y: safePos.y, width, height }, false);
    widgetWindow.setOpacity(1);
    widgetWindow.show();

    if (typeof widgetWindow.moveTop === 'function') {
        widgetWindow.moveTop();
    }

    if (focus) {
        widgetWindow.focus();
    }

    widgetWindow.webContents.send('widget-focus');
}

function createWindow() {
    mainWindow = new BrowserWindow({
        width: 1400,
        height: 900,
        minWidth: 800,
        minHeight: 600,
        frame: false,           // 隐藏原生标题栏
        titleBarStyle: 'hidden',
        icon: path.join(__dirname, 'assets', 'icon.ico'),
        webPreferences: {
            nodeIntegration: false,
            contextIsolation: true,
            sandbox: true,
            preload: path.join(__dirname, 'preload.js'),
            devTools: !app.isPackaged
        },
        backgroundColor: '#fdfdfd'
    });
    secureWindow(mainWindow);

    mainWindow.loadFile('index.html');

    // 监听开发者工具的打开/关闭
    // mainWindow.webContents.on('devtools-opened', () => {
    //     console.log('开发者工具已打开');
    // });
    // mainWindow.webContents.on('devtools-closed', () => {
    //     console.log('开发者工具已关闭');
    // });

    mainWindow.on('closed', () => {
        mainWindow = null;
        if (isQuitting) {
            if (widgetWindow && !widgetWindow.isDestroyed()) {
                widgetWindow.close();
            }
        }
    });
}

// IPC 窗口控制
ipcMain.on('window-minimize', () => {
    if (mainWindow) mainWindow.minimize();
});

ipcMain.on('window-maximize', () => {
    if (mainWindow) {
        if (mainWindow.isMaximized()) {
            mainWindow.unmaximize();
        } else {
            mainWindow.maximize();
        }
    }
});

ipcMain.on('window-close', () => {
    const settings = readSettings();
    if (settings.minimizeToTray === undefined) {
        // 首次关闭，询问用户选择
        if (mainWindow) mainWindow.webContents.send('ask-close-behavior');
    } else if (settings.minimizeToTray) {
        if (mainWindow) mainWindow.hide();
        if (!mainTray) createMainTray();
    } else {
        isQuitting = true;
        if (mainWindow) mainWindow.close();
    }
});

// 用户从关闭行为对话框直接执行
ipcMain.on('window-close-direct', () => {
    const settings = readSettings();
    if (settings.minimizeToTray) {
        if (mainWindow) mainWindow.hide();
        if (!mainTray) createMainTray();
    } else {
        isQuitting = true;
        if (mainWindow) mainWindow.close();
    }
});

ipcMain.on('app-quit', () => {
    isQuitting = true;
    if (mainWindow) mainWindow.close();
    if (widgetWindow && !widgetWindow.isDestroyed()) widgetWindow.close();
    app.quit();
});

ipcMain.on('get-close-behavior', (e) => {
    e.reply('close-behavior', readSettings().minimizeToTray);
});

ipcMain.on('set-close-behavior', (e, val) => {
    const settings = readSettings();
    settings.minimizeToTray = val;
    writeSettings(settings);
});
ipcMain.on('get-widget-opacity', (e) => {
    e.reply('widget-opacity', readSettings().widgetBlurOpacity ?? 0.94);
});
ipcMain.on('set-widget-opacity', (e, val) => {
    const settings = readSettings();
    settings.widgetBlurOpacity = Number.isFinite(Number(val))
        ? Math.max(0.5, Math.min(1, Number(val)))
        : 0.94;
    writeSettings(settings);
});
ipcMain.on('widget-data-read', (event) => {
    event.returnValue = isTrustedRenderer(event) ? readWidgetDataText() : null;
});
ipcMain.on('widget-data-write', (event, value) => {
    event.returnValue = isTrustedRenderer(event)
        ? writeWidgetDataText(value)
        : { ok: false, error: 'untrusted renderer' };
});

// 启动小组件
ipcMain.on('launch-widget', (event) => {
    const alreadyOpen = widgetWindow && !widgetWindow.isDestroyed();
    launchWidget();
    // 通知主窗口是否已打开
    event.reply('widget-launch-result', { alreadyOpen });
});

// 小组件置顶切换
ipcMain.on('widget-toggle-top', (e, val) => {
    if (widgetWindow && !widgetWindow.isDestroyed()) {
        widgetWindow.setAlwaysOnTop(val);
    }
});

// 小组件请求打开主窗口
ipcMain.on('widget-open-main', () => {
    if (mainWindow) {
        mainWindow.show();
        mainWindow.focus();
    }
});

// 主应用通知小组件刷新
ipcMain.on('main-data-changed', () => {
    if (widgetWindow && !widgetWindow.isDestroyed()) {
        widgetWindow.webContents.send('refresh-widget-data');
    }
});

// 小组件通知主应用刷新
ipcMain.on('widget-data-changed', () => {
    if (mainWindow && !mainWindow.isDestroyed()) {
        mainWindow.webContents.send('refresh-main-data');
    }
});

// 小组件请求打开任务详情（普通任务）
ipcMain.on('widget-open-task-detail', (e, taskId) => {
    if (mainWindow) {
        mainWindow.show();
        mainWindow.focus();
        mainWindow.webContents.send('open-task-detail', taskId);
    }
});

// 小组件请求打开项目任务详情（项目下的任务 → 思维导图视图 + 右侧详情面板）
ipcMain.on('widget-open-project-task-detail', (e, { projectId, taskId }) => {
    if (mainWindow) {
        mainWindow.show();
        mainWindow.focus();
        mainWindow.webContents.send('open-project-task-detail', { projectId, taskId });
    }
});

function launchWidget() {
    // 如果已经打开，聚焦并显示
    if (widgetWindow && !widgetWindow.isDestroyed()) {
        revealWidgetWindow();
        console.log('[Widget] 小组件已在运行，聚焦窗口');
        return;
    }

    try {
        const fs = require('fs');

        // 恢复窗口位置
        let posX, posY;
        try {
            const posFile = path.join(process.env.APPDATA || '', 'ProLife-Claude', 'widget-pos.json');
            if (fs.existsSync(posFile)) {
                const pos = JSON.parse(fs.readFileSync(posFile, 'utf-8'));
                posX = pos.x;
                posY = pos.y;
            }
        } catch(e) {}

        const initialPos = getSafeWidgetPosition(posX, posY, WIDGET_WIDTH, WIDGET_HEIGHT);

        widgetWindow = new BrowserWindow({
            width: WIDGET_WIDTH,
            height: WIDGET_HEIGHT,
            x: initialPos.x,
            y: initialPos.y,
            frame: false,
            transparent: true,
            alwaysOnTop: true,
            resizable: true,
            minimizable: false,
            maximizable: false,
            skipTaskbar: true,
            icon: path.join(__dirname, 'assets', 'icon.ico'),
            webPreferences: {
                nodeIntegration: false,
                contextIsolation: true,
                sandbox: true,
                preload: path.join(__dirname, 'widget', 'preload.js'),
                devTools: !app.isPackaged
            }
        });
        secureWindow(widgetWindow);

        widgetWindow.loadFile(path.join(__dirname, 'widget', 'widget.html'));

        // 记住窗口位置（防抖）
        let posSaveTimer = null;
        widgetWindow.on('moved', () => {
            if (widgetWindow.isDestroyed()) return;
            clearTimeout(posSaveTimer);
            posSaveTimer = setTimeout(() => {
                if (widgetWindow && !widgetWindow.isDestroyed()) {
                    const pos = widgetWindow.getPosition();
                    try {
                        const dir = path.join(process.env.APPDATA || '', 'ProLife-Claude');
                        if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
                        fs.writeFileSync(path.join(dir, 'widget-pos.json'), JSON.stringify({ x: pos[0], y: pos[1] }));
                    } catch(e) {}
                }
            }, 300);
        });

        widgetWindow.on('closed', () => {
            widgetWindow = null;
            // 清理托盘图标
            if (widgetTray) {
                widgetTray.destroy();
                widgetTray = null;
            }
        });

        // 置顶模式下失焦变透明
        widgetWindow.on('blur', () => {
            if (widgetWindow && !widgetWindow.isDestroyed() && widgetWindow.isAlwaysOnTop()) {
                widgetWindow.setOpacity(readSettings().widgetBlurOpacity ?? 0.94);
                widgetWindow.webContents.send('widget-blur');
            }
        });
        widgetWindow.on('focus', () => {
            if (widgetWindow && !widgetWindow.isDestroyed()) {
                widgetWindow.setOpacity(1);
                widgetWindow.webContents.send('widget-focus');
            }
        });

        // 创建托盘图标
        createWidgetTray();
        revealWidgetWindow();

        console.log('[Widget] 小组件窗口已创建');

    } catch (e) {
        console.error('[Widget] 启动异常:', e);
    }
}

function createWidgetTray() {
    if (widgetTray) return;

    const iconPath = path.join(__dirname, 'assets', 'icon.ico');
    let trayIcon;
    try {
        trayIcon = nativeImage.createFromPath(iconPath).resize({ width: 16, height: 16 });
    } catch(e) {
        trayIcon = nativeImage.createEmpty();
    }

    widgetTray = new Tray(trayIcon);
    widgetTray.setToolTip('Todo Widget');

    const contextMenu = Menu.buildFromTemplate([
        { label: '显示/隐藏', click: () => {
            if (widgetWindow && !widgetWindow.isDestroyed()) {
                if (widgetWindow.isVisible()) widgetWindow.hide();
                else revealWidgetWindow({ focus: false });
            }
        }},
        { label: '刷新', click: () => {
            if (widgetWindow && !widgetWindow.isDestroyed()) widgetWindow.reload();
        }},
        { type: 'separator' },
        { label: '关闭小组件', click: () => {
            if (widgetWindow && !widgetWindow.isDestroyed()) widgetWindow.close();
        }}
    ]);

    widgetTray.setContextMenu(contextMenu);
    widgetTray.on('click', () => {
        if (widgetWindow && !widgetWindow.isDestroyed()) {
            if (widgetWindow.isVisible()) widgetWindow.hide();
            else revealWidgetWindow({ focus: false });
        }
    });
}

// 创建菜单（隐藏）
function createMenu() {
    const template = [
        {
            label: '文件',
            submenu: [
                {
                    label: '重新加载',
                    accelerator: 'CmdOrCtrl+R',
                    click: () => {
                        if (mainWindow) mainWindow.reload();
                    }
                },
                { type: 'separator' },
                {
                    label: '退出',
                    accelerator: 'CmdOrCtrl+Q',
                    click: () => {
                        app.quit();
                    }
                }
            ]
        },
        {
            label: '编辑',
            submenu: [
                { label: '撤销', accelerator: 'CmdOrCtrl+Z', role: 'undo' },
                { label: '重做', accelerator: 'CmdOrCtrl+Y', role: 'redo' },
                { type: 'separator' },
                { label: '剪切', accelerator: 'CmdOrCtrl+X', role: 'cut' },
                { label: '复制', accelerator: 'CmdOrCtrl+C', role: 'copy' },
                { label: '粘贴', accelerator: 'CmdOrCtrl+V', role: 'paste' }
            ]
        },
        {
            label: '视图',
            submenu: [
                { label: '放大', accelerator: 'CmdOrCtrl+Plus', role: 'zoomIn' },
                { label: '缩小', accelerator: 'CmdOrCtrl+-', role: 'zoomOut' },
                { label: '重置缩放', accelerator: 'CmdOrCtrl+0', role: 'resetZoom' },
                { type: 'separator' },
                { label: '切换全屏', accelerator: 'F11', role: 'togglefullscreen' }
            ]
        }
    ];

    const menu = Menu.buildFromTemplate(template);
    Menu.setApplicationMenu(menu);
}

app.whenReady().then(() => {
    createWindow();
    createMenu();
});

app.on('window-all-closed', () => {
    if (isQuitting && process.platform !== 'darwin') {
        app.quit();
    }
});

function createMainTray() {
    if (mainTray) return;
    const iconPath = path.join(__dirname, 'assets', 'icon.ico');
    let trayIcon;
    try {
        trayIcon = nativeImage.createFromPath(iconPath).resize({ width: 16, height: 16 });
    } catch(e) {
        trayIcon = nativeImage.createEmpty();
    }
    mainTray = new Tray(trayIcon);
    mainTray.setToolTip('Todo');
    const contextMenu = Menu.buildFromTemplate([
        { label: '显示主窗口', click: () => {
            if (mainWindow) {
                mainWindow.show();
                mainWindow.focus();
            }
        }},
        { type: 'separator' },
        { label: '退出', click: () => {
            isQuitting = true;
            if (widgetWindow && !widgetWindow.isDestroyed()) widgetWindow.close();
            if (mainWindow) mainWindow.close();
            app.quit();
        }}
    ]);
    mainTray.setContextMenu(contextMenu);
    mainTray.on('click', () => {
        if (mainWindow) {
            if (mainWindow.isVisible()) {
                mainWindow.focus();
            } else {
                mainWindow.show();
                mainWindow.focus();
            }
        }
    });
}

app.on('activate', () => {
    if (mainWindow === null) {
        createWindow();
    }
});
