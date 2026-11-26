'use strict';

const pushAvailable = () => 'serviceWorker' in navigator && 'PushManager' in window && 'Notification' in window;

function pushPublicKey() {
  const key = window.STAGE_PUSH_PUBLIC_KEY;
  if (typeof key !== 'string' || !/^[A-Za-z0-9_-]{87}$/.test(key)) return null;
  return Uint8Array.from(atob(key.replaceAll('-', '+').replaceAll('_', '/') + '='), char => char.charCodeAt(0));
}

async function enableStagePush() {
  const key = pushPublicKey();
  if (!key || !pushAvailable()) throw Error('Push недоступний у цьому браузері');
  const permission = Notification.permission === 'default' ? await Notification.requestPermission() : Notification.permission;
  if (permission !== 'granted') throw Error('Дозвольте сповіщення в налаштуваннях браузера');
  const registration = await navigator.serviceWorker.getRegistration();
  if (!registration?.active) throw Error('Оновіть Stage Base і повторіть після запуску PWA');

  // Subscribe from the click handler. WebKit requires user interaction for permission.
  const subscription = await registration.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: key });
  const data = subscription.toJSON();
  try {
    await take(db.rpc('stage_register_push', {
      p_endpoint: data.endpoint, p_key: data.keys.p256dh, p_auth: data.keys.auth,
    }));
  } catch (error) {
    await subscription.unsubscribe().catch(() => {});
    throw error;
  }
}

async function disableStagePush() {
  if (!pushAvailable()) return;
  const registration = await navigator.serviceWorker.getRegistration();
  const subscription = await registration?.pushManager.getSubscription();
  if (!subscription) return;
  // Unsubscribe locally even if the server write fails or the session expired.
  try {
    await take(db.rpc('stage_disable_push', { p_endpoint: subscription.endpoint }));
  } finally {
    await subscription.unsubscribe();
  }
}

function pushControls(parent) {
  if (!pushPublicKey()) return;
  const section = document.createElement('section');
  section.className = 'card';
  const title = document.createElement('h2');
  title.textContent = 'Системні сповіщення';
  const info = document.createElement('p');
  info.textContent = 'На iPhone відкрийте Stage Base з домашнього екрана. Якщо застосунку там немає, додайте його через меню «Поширити» в Safari.';
  section.append(title, info);
  if (pushAvailable()) {
    for (const [label, fn, result] of [
      ['Увімкнути Push на цьому пристрої', enableStagePush, 'Push увімкнено'],
      ['Вимкнути Push на цьому пристрої', disableStagePush, 'Push вимкнено'],
    ]) {
      const button = document.createElement('button');
      button.className = 'full';
      button.textContent = label;
      button.onclick = async () => {
        button.disabled = true;
        try { await fn(); toast(result); } catch (error) { fail(error); }
        finally { button.disabled = false; }
      };
      section.append(button);
    }
  }
  parent.append(section);
}
