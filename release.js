'use strict';

const stageRelease = '2.2.2';

function startReleaseUpdates() {
  if (!('serviceWorker' in navigator)) return;
  const workers = navigator.serviceWorker;
  let activateRequested = false;
  let reloading = false;
  workers.addEventListener('controllerchange', () => {
    if (!activateRequested || reloading) return;
    reloading = true;
    location.reload();
  });

  function offerUpdate(waiting) {
    if (!waiting || !workers.controller || document.querySelector('#stage-update')) return;
    const banner = document.createElement('aside');
    banner.id = 'stage-update';
    banner.setAttribute('aria-live', 'polite');
    const label = document.createElement('span');
    label.textContent = 'Доступна нова версія Stage Base';
    const update = document.createElement('button');
    update.type = 'button';
    update.className = 'primary';
    update.textContent = 'Оновити';
    update.onclick = () => {
      if (document.querySelector('dialog[open]')) {
        label.textContent = 'Збережіть або закрийте форму, потім оновіть застосунок.';
        return;
      }
      update.disabled = true;
      activateRequested = true;
      waiting.postMessage({ type: 'STAGE_ACTIVATE_UPDATE' });
      setTimeout(() => {
        if (reloading) return;
        activateRequested = false;
        update.disabled = false;
        label.textContent = 'Оновлення ще очікує. Спробуйте повторити.';
      }, 10000);
    };
    banner.append(label, update);
    document.body.append(banner);
  }

  workers.register('./offline.js', { updateViaCache: 'none' }).then(registration => {
    const observe = worker => {
      if (!worker) return;
      worker.addEventListener('statechange', () => {
        if (worker.state === 'installed') offerUpdate(registration.waiting || worker);
      });
    };
    offerUpdate(registration.waiting);
    observe(registration.installing);
    registration.addEventListener('updatefound', () => observe(registration.installing));
    let lastCheck = 0;
    const check = () => {
      if (document.hidden || !navigator.onLine || Date.now() - lastCheck < 15000) return;
      lastCheck = Date.now();
      registration.update().catch(() => {});
    };
    window.addEventListener('online', check);
    document.addEventListener('visibilitychange', check);
    setInterval(check, 60000);
    check();
  }).catch(error => console.warn('Stage Base: оновлення PWA недоступне', error));
}

startReleaseUpdates();
