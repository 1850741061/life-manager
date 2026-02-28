const { app, BrowserWindow, Menu, Tray, nativeImage, ipcMain } = require('electron');
const path = require('path');

let mainWindow;
let widgetWindow = null;
let widgetTray = null;

function createWindow() {
    mainWindow = new BrowserWindow({
        width: 1400,
        height: 900,
        minWidth: 800,
        minHeight: 600,
        frame: false,           // 隐藏原生标题栏
        titleBarStyle: 'hidden',
        icon: path.join(__dirname, 'assets', 'icon.png'),
        webPreferences: {
            nodeIntegration: true,
            contextIsolation: false,
            devTools: true       // 启用开发者工具，但自动打开
        },
        backgroundColor: '#fdfdfd'
    });

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
        // 主窗口关闭时也关闭小组件
        if (widgetWindow && !widgetWindow.isDestroyed()) {
            widgetWindow.close();
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
    if (mainWindow) mainWindow.close();
});

// 启动小组件
ipcMain.on('launch-widget', () => {
    launchWidget();
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

function launchWidget() {
    // 如果已经打开，聚焦并显示
    if (widgetWindow && !widgetWindow.isDestroyed()) {
        widgetWindow.show();
        widgetWindow.focus();
        console.log('[Widget] 小组件已在运行，聚焦窗口');
        return;
    }

    try {
        const fs = require('fs');

        // 恢复窗口位置
        let posX, posY;
        try {
            const posFile = path.join(process.env.APPDATA || '', 'ProLife', 'widget-pos.json');
            if (fs.existsSync(posFile)) {
                const pos = JSON.parse(fs.readFileSync(posFile, 'utf-8'));
                posX = pos.x;
                posY = pos.y;
            }
        } catch(e) {}

        widgetWindow = new BrowserWindow({
            width: 400,
            height: 700,
            x: posX,
            y: posY,
            frame: false,
            transparent: true,
            alwaysOnTop: true,
            resizable: true,
            minimizable: false,
            maximizable: false,
            skipTaskbar: true,
            icon: path.join(__dirname, 'assets', 'icon.png'),
            webPreferences: {
                nodeIntegration: true,
                contextIsolation: false
            }
        });

        widgetWindow.loadFile(path.join(__dirname, 'widget', 'widget.html'));

        // 记住窗口位置
        widgetWindow.on('moved', () => {
            if (widgetWindow.isDestroyed()) return;
            const pos = widgetWindow.getPosition();
            try {
                const dir = path.join(process.env.APPDATA || '', 'ProLife');
                if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
                fs.writeFileSync(path.join(dir, 'widget-pos.json'), JSON.stringify({ x: pos[0], y: pos[1] }));
            } catch(e) {}
        });

        widgetWindow.on('closed', () => {
            widgetWindow = null;
            // 清理托盘图标
            if (widgetTray) {
                widgetTray.destroy();
                widgetTray = null;
            }
        });

        // 创建托盘图标
        createWidgetTray();

        console.log('[Widget] 小组件窗口已创建');

    } catch (e) {
        console.error('[Widget] 启动异常:', e);
    }
}

function createWidgetTray() {
    if (widgetTray) return;

    const iconPath = path.join(__dirname, 'assets', 'icon.png');
    let trayIcon;
    try {
        trayIcon = nativeImage.createFromPath(iconPath).resize({ width: 16, height: 16 });
    } catch(e) {
        trayIcon = nativeImage.createEmpty();
    }

    widgetTray = new Tray(trayIcon);
    widgetTray.setToolTip('ProLife Widget');

    const contextMenu = Menu.buildFromTemplate([
        { label: '显示/隐藏', click: () => {
            if (widgetWindow && !widgetWindow.isDestroyed()) {
                if (widgetWindow.isVisible()) widgetWindow.hide();
                else widgetWindow.show();
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
            else widgetWindow.show();
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
    if (process.platform !== 'darwin') {
        app.quit();
    }
});

app.on('activate', () => {
    if (mainWindow === null) {
        createWindow();
    }
});
