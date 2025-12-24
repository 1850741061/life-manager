const CACHE_NAME = 'prolife-v2';

// 安装 Service Worker
self.addEventListener('install', (event) => {
    event.waitUntil(
        caches.open(CACHE_NAME)
            .then((cache) => cache.addAll([
                './',
                './index.html',
                './manifest.json'
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
                    // 删除所有旧版本的缓存
                    if (cacheName !== CACHE_NAME) {
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
