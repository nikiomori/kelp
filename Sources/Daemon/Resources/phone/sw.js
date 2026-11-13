// Push, and the page's own files for a launch with no network. The network always goes first, so a stale script is
// only ever run offline, where it just says it can't reach the Mac and retries. The Mac's calls (/api/) never touch
// the cache.

const SHELL = 'kelp-shell';
self.addEventListener('install', event => {
  self.skipWaiting();
  event.waitUntil(caches.open(SHELL).then(cache => cache.addAll([
    '/', '/app.css', '/app.js', '/js/api.js', '/js/md.js', '/js/glass.js', '/icons/marks.svg', '/icons/192.png', '/manifest.webmanifest',
  ])).catch(() => {}));
});
self.addEventListener('activate', event => event.waitUntil(self.clients.claim()));

self.addEventListener('fetch', event => {
  const { request } = event, url = new URL(request.url);
  if (request.method !== 'GET' || url.origin !== location.origin || url.pathname.startsWith('/api/')) return;
  // A launch from the Home Screen asks for the start address (maybe with ?query), which is the page itself.
  const key = request.mode === 'navigate' ? '/' : request;
  event.respondWith(fetch(request).then(res => {
    if (res.ok) {
      const copy = res.clone();
      event.waitUntil(caches.open(SHELL).then(cache => cache.put(key, copy)));
    }
    return res;
  }, () => caches.match(key).then(hit => hit ?? Response.error())));
});

self.addEventListener('push', event => {
  // Every push shows a notification, even one that can't be read: Safari takes the subscription away from a page
  // that receives pushes silently.
  let data = {};
  try { data = event.data.json() ?? {}; } catch {}
  const agent = typeof data.agent === 'string' ? data.agent : '';
  event.waitUntil(Promise.all([
    self.registration.showNotification(typeof data.title === 'string' ? data.title : 'Kelp', {
      body: typeof data.body === 'string' ? data.body : 'An agent needs you.',
      icon: '/icons/192.png',   // iOS draws the app's own; others need one
      tag: agent || 'kelp',   // one per agent: a new one replaces the old
      data: { agent },
    }),
    Number.isInteger(data.waiting) && navigator.setAppBadge?.(data.waiting)?.catch(() => {}),
  ]));
});

self.addEventListener('notificationclick', event => {
  event.notification.close();
  const agent = event.notification.data?.agent ?? '';
  event.waitUntil(
    self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(windows => {
      const page = windows[0];
      if (!page) return self.clients.openWindow('/#' + encodeURIComponent(agent));
      page.postMessage({ agent });   // the page moves itself to /#<agent>
      return page.focus();
    }),
  );
});
