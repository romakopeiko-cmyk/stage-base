'use strict';

self.addEventListener('activate', event => event.waitUntil(self.clients.claim()));
self.addEventListener('fetch', event => {
  if (event.request.mode !== 'navigate' || event.request.method !== 'GET' ||
    !event.request.url.startsWith(self.registration.scope)) return;
  event.respondWith(fetch(event.request, { cache: 'no-cache' }).catch(() => new Response(
    '<!doctype html><html lang="uk"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Stage Base Staging</title><h1>Немає підключення</h1><p>Відновіть зв’язок і оновіть сторінку.</p>',
    { status: 503, headers: { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' } }
  )));
});
