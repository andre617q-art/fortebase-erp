// ============================================================
// 建材ERP · Service Worker
// 版本号：每次更新HTML时，修改这里的版本强制刷新缓存
// ============================================================
const CACHE_VERSION = 'fortebase-v1-002';
const CACHE_NAME    = CACHE_VERSION;

// 预缓存资源（首次安装时缓存，保证离线可用）
const PRECACHE_URLS = [
  './',
  './index.html',
  './manifest.json',
  './icons/icon-192.png',
  './icons/icon-512.png',
  // CDN 资源 — 缓存后断网也能用
  'https://cdn.jsdelivr.net/npm/localforage@1.10.0/dist/localforage.min.js',
  'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/dist/umd/supabase.min.js',
  'https://cdn.jsdelivr.net/npm/@zxing/library@0.19.1/umd/index.min.js',
  'https://cdn.jsdelivr.net/npm/jsbarcode@3.11.6/dist/JsBarcode.all.min.js',
];

// ── 安装事件：预缓存所有资源 ──
self.addEventListener('install', event => {
  console.log('[SW] Installing version:', CACHE_VERSION);
  event.waitUntil(
    caches.open(CACHE_NAME)
      .then(cache => {
        // 逐个缓存，单个失败不影响整体
        return Promise.allSettled(
          PRECACHE_URLS.map(url =>
            cache.add(url).catch(err =>
              console.warn('[SW] Failed to cache:', url, err.message)
            )
          )
        );
      })
      .then(() => self.skipWaiting()) // 立即激活，不等旧SW退出
  );
});

// ── 激活事件：清除旧版本缓存 ──
self.addEventListener('activate', event => {
  console.log('[SW] Activating version:', CACHE_VERSION);
  event.waitUntil(
    caches.keys().then(cacheNames =>
      Promise.all(
        cacheNames
          .filter(name => name !== CACHE_NAME)
          .map(name => {
            console.log('[SW] Deleting old cache:', name);
            return caches.delete(name);
          })
      )
    ).then(() => self.clients.claim()) // 立即接管所有页面
  );
});

// ── 拦截请求：网络优先 + 离线降级 ──
self.addEventListener('fetch', event => {
  const url = new URL(event.request.url);

  // Supabase API 请求：永远走网络，不缓存（数据必须实时）
  if (url.hostname.includes('supabase.co') ||
      url.hostname.includes('googleapis.com') ||
      url.hostname.includes('wa.me')) {
    return; // 不拦截，让浏览器正常处理
  }

  // 字体：缓存优先（字体很少变）
  if (url.hostname === 'fonts.googleapis.com' ||
      url.hostname === 'fonts.gstatic.com') {
    event.respondWith(
      caches.match(event.request).then(cached => {
        if (cached) return cached;
        return fetch(event.request).then(response => {
          if (response.ok) {
            const clone = response.clone();
            caches.open(CACHE_NAME).then(cache => cache.put(event.request, clone));
          }
          return response;
        });
      })
    );
    return;
  }

  // CDN 脚本：缓存优先（版本锁定，不会变）
  if (url.hostname === 'cdn.jsdelivr.net') {
    event.respondWith(
      caches.match(event.request).then(cached => {
        if (cached) return cached;
        return fetch(event.request).then(response => {
          if (response.ok) {
            const clone = response.clone();
            caches.open(CACHE_NAME).then(cache => cache.put(event.request, clone));
          }
          return response;
        }).catch(() => {
          // CDN 离线，返回空响应避免报错
          return new Response('/* offline */', {
            headers: { 'Content-Type': 'application/javascript' }
          });
        });
      })
    );
    return;
  }

  // 主应用文件（HTML/图标/manifest）：网络优先，失败用缓存
  event.respondWith(
    fetch(event.request)
      .then(response => {
        // 更新缓存（静默后台更新）
        if (response.ok && event.request.method === 'GET') {
          const clone = response.clone();
          caches.open(CACHE_NAME).then(cache => cache.put(event.request, clone));
        }
        return response;
      })
      .catch(() => {
        // 网络失败，从缓存返回
        return caches.match(event.request).then(cached => {
          if (cached) return cached;
          // 如果是页面请求，返回主页（离线也能打开APP）
          if (event.request.destination === 'document') {
            return caches.match('./index.html');
          }
          return new Response('Offline', { status: 503 });
        });
      })
  );
});

// ── 后台同步（当网络恢复时触发）──
self.addEventListener('sync', event => {
  if (event.tag === 'erp-sync') {
    console.log('[SW] Background sync triggered');
    // 通知主页面执行云同步
    self.clients.matchAll().then(clients => {
      clients.forEach(client =>
        client.postMessage({ type: 'BACKGROUND_SYNC' })
      );
    });
  }
});

// ── 接收来自主页面的消息 ──
self.addEventListener('message', event => {
  if (event.data && event.data.type === 'SKIP_WAITING') {
    self.skipWaiting();
  }
});
