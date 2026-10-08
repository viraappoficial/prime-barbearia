const SHELL_CACHE = 'prime-shell-v5';
const SHELL_FILES = ['./', 'index.html', 'manifest.json', 'manifest-staff.json', 'icon-192.png', 'icon-512.png',
  'splash-1170x2532.png', 'splash-1179x2556.png', 'splash-1284x2778.png', 'splash-1290x2796.png', 'splash-828x1792.png', 'splash-750x1334.png'];

self.addEventListener('install', (event) => {
  event.waitUntil(caches.open(SHELL_CACHE).then(cache => cache.addAll(SHELL_FILES)));
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then(keys => Promise.all(keys.filter(k => k !== SHELL_CACHE).map(k => caches.delete(k))))
  );
  self.clients.claim();
});

self.addEventListener('fetch', (event) => {
  const req = event.request;
  if (req.method !== 'GET') return; // nunca cacheia POST/PATCH (chamadas ao Supabase)
  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return; // fontes/CDN do Supabase seguem direto pra rede, sem cache

  // network-first pro shell: sempre tenta rede primeiro (pra pegar atualizações), cai pro cache se offline.
  // cache:'no-store' é essencial aqui — sem isso o navegador pode responder com o HTTP cache dele mesmo,
  // e a gente nunca saberia se pegou uma versão nova de verdade ou uma antiga "requentada"
  event.respondWith(
    fetch(req, { cache: 'no-store' }).then(res => {
      const copy = res.clone();
      caches.open(SHELL_CACHE).then(cache => cache.put(req, copy));
      return res;
    }).catch(() => caches.match(req).then(cached => cached || caches.match('index.html')))
  );
});

self.addEventListener('push', (event) => {
  const data = event.data ? event.data.json() : {};
  event.waitUntil(self.registration.showNotification(data.title || 'Prime Barbearia', {
    body: data.body || '',
    icon: 'icon-192.png',
    badge: 'icon-192.png',
    tag: data.apptId ? 'appt-' + data.apptId : undefined,
    vibrate: [250, 120, 250],
    data: { apptId: data.apptId ?? null, notifType: data.notifType ?? null }
  }));
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  event.waitUntil(
    clients.matchAll({ type: 'window', includeUncontrolled: true }).then((list) => {
      for (const c of list) { if (new URL(c.url).origin === self.location.origin && 'focus' in c) return c.focus(); }
      return clients.openWindow('./');
    })
  );
});
