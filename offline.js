// Navigation stays online. Auth responses and signed Storage URLs never enter Cache Storage.
self.addEventListener('fetch', event => {
  if (event.request.mode !== 'navigate' || event.request.method !== 'GET') return;
  if (new URL(event.request.url).origin !== self.location.origin) return;

  event.respondWith(fetch(event.request).catch(() => new Response(
    '<!doctype html><html lang="uk"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Stage Base</title><h1>Немає підключення</h1><p>Відновіть інтернет-з’єднання та оновіть сторінку.</p>',
    { status: 503, headers: { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' } }
  )));
});
