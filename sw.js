const CACHE_NAME = 'todo-claude-v2-sync-safe';
const CACHE_PREFIX = 'todo-claude-';
const LEGACY_CACHE_NAMES = new Set(['todo-v2-sync-safe']);

// 安装 Service Worker
self.addEventListener('install', (event) => {
    event.waitUntil(
        caches.open(CACHE_NAME)
            .then((cache) => cache.addAll([
                './',
                './index.html',
                './manifest.json',
                './sw.js',
                './assets/icon.png'
            ]))
            .then(() => self.skipWaiting())
    );
});

// 激活 Service Worker - 清除旧缓存
self.addEventListener('activate', (event) => {
    event.waitUntil(
        caches.keys().then((cacheNames) => {
            return Promise.all(
                cacheNames.map((cacheName) => {
                    // 只清理本应用的旧缓存；同源的其它应用由各自
                    // 的前缀管理，不能在这里删除。
                    if ((cacheName.startsWith(CACHE_PREFIX) || LEGACY_CACHE_NAMES.has(cacheName))
                        && cacheName !== CACHE_NAME) {
                        return caches.delete(cacheName);
                    }
                })
            );
        })
    );
    self.clients.claim();
});

// 拦截网络请求 - 网络优先，缓存作为后备
self.addEventListener('fetch', (event) => {
    event.respondWith(
        fetch(event.request)
            .then((response) => {
                // 检查是否是有效响应
                if (!response || response.status !== 200 || response.type !== 'basic') {
                    return response;
                }
                // 克隆响应
                const responseToCache = response.clone();
                caches.open(CACHE_NAME)
                    .then((cache) => {
                        cache.put(event.request, responseToCache);
                    });
                return response;
            })
            .catch(() => {
                // 网络失败时使用缓存
                return caches.match(event.request);
            })
    );
});
