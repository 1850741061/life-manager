const { app, BrowserWindow, Tray, Menu, nativeImage, ipcMain } = require('electron');
const path = require('path');

let win;
let tray;

function createWindow() {
    win = new BrowserWindow({
        width: 400,
        height: 700,
        frame: false,
        transparent: true,
        alwaysOnTop: true,
        resizable: true,
        minimizable: false,
        maximizable: false,
        skipTaskbar: true,
        icon: path.join(__dirname, '..', 'assets', 'icon.png'),
        webPreferences: {
            nodeIntegration: true,
            contextIsolation: false
        }
    });

    win.loadFile(path.join(__dirname, 'widget.html'));

    // 记住窗口位置
    win.on('moved', () => {
        const pos = win.getPosition();
        try {
            const fs = require('fs');
            const dir = path.join(process.env.APPDATA || '', 'ProLife');
            if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
            fs.writeFileSync(path.join(dir, 'widget-pos.json'), JSON.stringify({ x: pos[0], y: pos[1] }));
        } catch(e) {}
    });

    // 恢复窗口位置
    try {
        const fs = require('fs');
        const posFile = path.join(process.env.APPDATA || '', 'ProLife', 'widget-pos.json');
        if (fs.existsSync(posFile)) {
            const pos = JSON.parse(fs.readFileSync(posFile, 'utf-8'));
            win.setPosition(pos.x, pos.y);
        }
    } catch(e) {}

    win.on('closed', () => { win = null; });
}

function createTray() {
    // 创建一个简单的 16x16 托盘图标
    const iconPath = path.join(__dirname, '..', 'assets', 'icon.png');
    let trayIcon;
    try {
        trayIcon = nativeImage.createFromPath(iconPath).resize({ width: 16, height: 16 });
    } catch(e) {
        // 如果没有图标文件，创建一个空白图标
        trayIcon = nativeImage.createEmpty();
    }

    tray = new Tray(trayIcon);
    tray.setToolTip('ProLife Widget');

    const contextMenu = Menu.buildFromTemplate([
        { label: '刷新', click: () => { if (win) win.reload(); } },
        { label: '显示/隐藏', click: () => {
            if (win) {
                if (win.isVisible()) win.hide();
                else win.show();
            }
        }},
        { type: 'separator' },
        { label: '打开 ProLife', click: () => {
            const { exec } = require('child_process');
            exec(`cd /d "${path.join(__dirname, '..')}" && npx electron .`);
        }},
        { type: 'separator' },
        { label: '退出', click: () => { app.quit(); } }
    ]);

    tray.setContextMenu(contextMenu);
    tray.on('click', () => {
        if (win) {
            if (win.isVisible()) win.hide();
            else win.show();
        }
    });
}

// IPC handlers
ipcMain.on('widget-toggle-top', (e, val) => {
    if (win) win.setAlwaysOnTop(val);
});

app.whenReady().then(() => {
    createWindow();
    createTray();
});

app.on('window-all-closed', () => {
    // 不退出，保持托盘运行
});
