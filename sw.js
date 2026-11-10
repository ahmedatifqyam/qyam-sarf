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
