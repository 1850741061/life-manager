const { app, BrowserWindow, Menu, ipcMain } = require('electron');
const path = require('path');
const { spawn } = require('child_process');

let mainWindow;
let widgetProcess = null;

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

function launchWidget() {
    // 如果已经在运行，不重复启动
    if (widgetProcess && !widgetProcess.killed) {
        console.log('[Widget] 小组件已在运行');
        return;
    }

    try {
        const electronPath = process.execPath; // 当前 Electron 可执行文件路径
        const widgetMainPath = path.join(__dirname, 'widget', 'widget-main.js');

        console.log('[Widget] 启动小组件:', electronPath, widgetMainPath);

        widgetProcess = spawn(electronPath, [widgetMainPath], {
            detached: true,
            stdio: 'ignore',
            cwd: path.join(__dirname, 'widget')
        });

        widgetProcess.unref(); // 允许父进程独立退出

        widgetProcess.on('error', (err) => {
            console.error('[Widget] 启动失败:', err);
            widgetProcess = null;
        });

        widgetProcess.on('exit', (code) => {
            console.log('[Widget] 进程退出，代码:', code);
            widgetProcess = null;
        });

    } catch (e) {
        console.error('[Widget] 启动异常:', e);
    }
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
