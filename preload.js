const { contextBridge, ipcRenderer } = require('electron');

const SEND_CHANNELS = new Set([
  'window-minimize',
  'window-maximize',
  'window-close',
  'window-close-direct',
  'app-quit',
  'get-close-behavior',
  'set-close-behavior',
  'get-widget-opacity',
  'set-widget-opacity',
  'launch-widget',
  'main-data-changed',
]);

const RECEIVE_CHANNELS = new Set([
  'widget-launch-result',
  'refresh-main-data',
  'open-task-detail',
  'open-project-task-detail',
  'close-behavior',
  'widget-opacity',
  'ask-close-behavior',
  'open-settings',
]);

function addListener(channel, listener, once = false) {
  if (!RECEIVE_CHANNELS.has(channel) || typeof listener !== 'function') return () => {};
  const wrapped = (_event, ...args) => listener(undefined, ...args);
  if (once) ipcRenderer.once(channel, wrapped);
  else ipcRenderer.on(channel, wrapped);
  return () => ipcRenderer.removeListener(channel, wrapped);
}

contextBridge.exposeInMainWorld('desktopAPI', Object.freeze({
  isElectron: true,
  ipc: Object.freeze({
    send(channel, ...args) {
      if (SEND_CHANNELS.has(channel)) ipcRenderer.send(channel, ...args);
    },
    on(channel, listener) {
      return addListener(channel, listener, false);
    },
    once(channel, listener) {
      return addListener(channel, listener, true);
    },
  }),
  readWidgetData() {
    return ipcRenderer.sendSync('widget-data-read');
  },
  writeWidgetData(serialized) {
    return ipcRenderer.sendSync('widget-data-write', serialized);
  },
}));

