// Change this version on every release to trigger a service worker update.
const stageWorkerRelease = '2.2.0';

self.addEventListener('message', event => {
  if (event.data?.type === 'STAGE_ACTIVATE_UPDATE') event.waitUntil(self.skipWaiting());
});

self.addEventListener('activate', event => {
  event.waitUntil(self.clients.claim());
});

// Always revalidate navigation. Auth responses and private files never enter Cache Storage.
self.addEventListener('fetch', event => {
  if (event.request.mode !== 'navigate' || event.request.method !== 'GET') return;
  if (!event.request.url.startsWith(self.registration.scope)) return;
  event.respondWith(fetch(event.request, { cache: 'no-cache' }).catch(() => new Response(
    '<!doctype html><html lang="uk"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Stage Base</title><h1>Немає підключення</h1><p>Відновіть інтернет-з’єднання та оновіть сторінку.</p>',
    { status: 503, headers: {
      'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store', 'X-Stage-Version': stageWorkerRelease
    } }
  )));
});
