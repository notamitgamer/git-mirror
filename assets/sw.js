/* git-mirror service worker: network first so the mirror stays fresh, cache as the offline fallback. */
const PREFIX = 'git-mirror:' + self.registration.scope;   // other sites on the same origin keep their caches
const CACHE = PREFIX + ':v1';
const SHELL = ['./', '404.html', 'icon.svg', 'manifest.webmanifest'];
const MAX = 300;

self.addEventListener('install', (e) => {
  e.waitUntil(caches.open(CACHE).then((c) => c.addAll(SHELL)).then(() => self.skipWaiting()));
});
self.addEventListener('activate', (e) => {
  e.waitUntil(caches.keys()
    .then((ks) => Promise.all(ks.filter((k) => k.startsWith(PREFIX) && k !== CACHE).map((k) => caches.delete(k))))
    .then(() => self.clients.claim()));
});
async function handle(req) {
  const c = await caches.open(CACHE);
  try {
    const res = await fetch(req);
    if (res.ok) {
      await c.put(req, res.clone()).catch(() => {});
      const keys = await c.keys();
      if (keys.length > MAX) await c.delete(keys[SHELL.length]);
    }
    return res;
  } catch (err) {
    const hit = await c.match(req);
    if (hit) return hit;
    if (req.mode === 'navigate' || (req.headers.get('accept') || '').includes('text/html')) {
      return new Response('<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>Offline</title><body style="background:#11111b;color:#cdd6f4;font-family:system-ui;text-align:center;padding:20vh 16px"><h1>Offline</h1><p>This page has not been saved on this device yet.</p>',
        { status: 503, headers: { 'Content-Type': 'text/html; charset=utf-8' } });
    }
    throw err;
  }
}
self.addEventListener('fetch', (e) => {
  const req = e.request;
  if (req.method !== 'GET' || !req.url.startsWith(self.registration.scope)) return;
  e.respondWith(handle(req));
});
