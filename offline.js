// Navigation stays online. Auth responses and signed Storage URLs never enter Cache Storage.
self.addEventListener('fetch', event => {
  if (event.request.mode !== 'navigate' || event.request.method !== 'GET') return;
  if (new URL(event.request.url).origin !== self.location.origin) return;

  event.respondWith(fetch(event.request).catch(() => new Response(
    '<!doctype html><html lang="uk"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Stage Base</title><h1>Немає підключення</h1><p>Відновіть інтернет-з’єднання та оновіть сторінку.</p>',
    { status: 503, headers: { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' } }
  )));
});

self.addEventListener('push', event => {
  let tag = 'stage-notification';
  try {
    const payload = event.data?.json();
    if (/^stage-[0-9]+$/.test(payload?.tag || '')) tag = payload.tag;
  } catch {
    // Unsupported messages still show a generic notification.
  }
  event.waitUntil(self.registration.showNotification('Stage Base', {
    body: 'Нове сповіщення. Відкрийте центр сповіщень.',
    icon: new URL('./icons/stage-base-192.png', self.registration.scope).href,
    tag,
  }));
});

self.addEventListener('notificationclick', event => {
  event.notification.close();
  const inbox = new URL('./?page=notifications', self.registration.scope).href;
  event.waitUntil((async () => {
    const pages = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    const existing = pages.find(client => client.url.startsWith(self.registration.scope));
    if (existing && 'navigate' in existing) {
      const navigated = await existing.navigate(inbox);
      if (navigated) return navigated.focus();
    }
    return self.clients.openWindow(inbox);
  })());
});
