// عامل خدمة خفيف: الشبكة أولاً دائماً (لا نسخة قديمة تعلق)، ونسخة احتياطية للصفحة عند انقطاع الاتصال فقط.
// لا يخزّن أي طلب إلى قاعدة البيانات أو غيرها من المواقع.
const CACHE = 'qayam-shell-v1';
self.addEventListener('install', e => { self.skipWaiting(); });
self.addEventListener('activate', e => {
  e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k !== CACHE).map(k => caches.delete(k)))).then(() => self.clients.claim()));
});
self.addEventListener('fetch', e => {
  const r = e.request, u = new URL(r.url);
  if (r.method !== 'GET' || u.origin !== self.location.origin) return;
  e.respondWith(fetch(r).then(res => {
    if (res && res.ok) { const c = res.clone(); caches.open(CACHE).then(ca => ca.put(r, c)).catch(()=>{}); }
    return res;
  }).catch(() => caches.match(r).then(m => m || (r.mode === 'navigate' ? caches.match('./') : undefined) || Response.error())));
});

// إشعارات الجهاز: العرض، ثم فتح الطلب عند الضغط
self.addEventListener('push', e => {
  let d = {}; try { d = e.data ? e.data.json() : {}; } catch (x) { d = { title: 'نظام الصرف', body: e.data ? e.data.text() : '' }; }
  e.waitUntil(self.registration.showNotification(d.title || 'نظام الصرف', {
    body: d.body || '', tag: d.tag || undefined, renotify: !!d.tag, dir: 'rtl', lang: 'ar',
    icon: 'icons/icon-192.png', badge: 'icons/icon-192.png', data: { url: d.url || '' }
  }));
});
self.addEventListener('notificationclick', e => {
  e.notification.close();
  const url = (e.notification.data && e.notification.data.url) || '';
  const m = /[?&]req=([^&]+)/.exec(url), req = m ? decodeURIComponent(m[1]) : '';
  e.waitUntil(self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(list => {
    for (const c of list) {
      if (c.url.indexOf(self.registration.scope) === 0) { c.postMessage({ type: 'qy-open', req }); return c.focus(); }
    }
    return self.clients.openWindow(self.registration.scope + (url || ''));
  }));
});
