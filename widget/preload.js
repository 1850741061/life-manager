const { contextBridge, ipcRenderer } = require('electron');

const SEND_CHANNELS = new Set([
  'widget-data-changed',
  'widget-toggle-top',
  'widget-open-main',
  'widget-open-task-detail',
  'widget-open-project-task-detail',
]);

const RECEIVE_CHANNELS = new Set([
  'refresh-widget-data',
  'widget-blur',
  'widget-focus',
]);

function addListener(channel, listener) {
  if (!RECEIVE_CHANNELS.has(channel) || typeof listener !== 'function') return () => {};
  const wrapped = (_event, ...args) => listener(undefined, ...args);
  ipcRenderer.on(channel, wrapped);
  return () => ipcRenderer.removeListener(channel, wrapped);
}

contextBridge.exposeInMainWorld('desktopAPI', Object.freeze({
  isElectron: true,
  ipc: Object.freeze({
    send(channel, ...args) {
      if (SEND_CHANNELS.has(channel)) ipcRenderer.send(channel, ...args);
    },
    on(channel, listener) {
      return addListener(channel, listener);
    },
    once(channel, listener) {
      if (!RECEIVE_CHANNELS.has(channel) || typeof listener !== 'function') return () => {};
      const wrapped = (_event, ...args) => listener(undefined, ...args);
      ipcRenderer.once(channel, wrapped);
      return () => ipcRenderer.removeListener(channel, wrapped);
    },
  }),
  readWidgetData() {
    return ipcRenderer.sendSync('widget-data-read');
  },
  writeWidgetData(serialized) {
    return ipcRenderer.sendSync('widget-data-write', serialized);
  },
}));

