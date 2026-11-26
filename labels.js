'use strict';

let cameraSession;

function loadQrLibrary(global, url, integrity) {
  if (window[global]) return Promise.resolve(window[global]);

  return new Promise((resolve, reject) => {
    const script = document.createElement('script');
    script.src = url;
    script.integrity = integrity;
    script.crossOrigin = 'anonymous';
    script.onload = () => window[global]
      ? resolve(window[global])
      : reject(new Error('Не вдалося завантажити модуль QR'));
    script.onerror = () => {
      script.remove();
      reject(new Error('Не вдалося завантажити модуль QR'));
    };
    document.head.append(script);
  });
}

function stopCamera() {
  if (!cameraSession) return;

  cancelAnimationFrame(cameraSession.frame);
  cameraSession.stream?.getTracks().forEach(track => track.stop());
  cameraSession.video.srcObject = null;
  cameraSession.video.hidden = true;
  cameraSession.toggle.textContent = 'Увімкнути камеру';
  cameraSession = null;
}

async function scanCamera(video, toggle, status, onCode) {
  const session = { video, toggle };
  cameraSession = session;
  toggle.textContent = 'Зупинити камеру';
  status.textContent = 'Підключення камери…';

  try {
    if (!navigator.mediaDevices?.getUserMedia) {
      throw new Error('Камера недоступна в цьому браузері. Введіть номер вручну.');
    }

    const stream = await navigator.mediaDevices.getUserMedia({
      video: { facingMode: { ideal: 'environment' } },
      audio: false
    });
    if (cameraSession !== session) {
      stream.getTracks().forEach(track => track.stop());
      return;
    }

    session.stream = stream;
    const decode = await loadQrLibrary(
      'jsQR',
      'https://cdn.jsdelivr.net/npm/jsqr@1.4.0/dist/jsQR.js',
      'sha384-b5Ya4Bq3qCyz39m2ISh+4DxjAIljdeFwK/BsXLuj9gugaNwAcj/ia15fxNZL9Nlx'
    );
    if (cameraSession !== session) return;

    video.srcObject = stream;
    video.hidden = false;
    await video.play();
    if (cameraSession !== session) return;
    status.textContent = 'Наведіть камеру на QR-код.';
    const canvas = document.createElement('canvas');
    const context = canvas.getContext('2d', { willReadFrequently: true });
    let lastScan = -Infinity;

    function scanFrame(time) {
      if (video.readyState >= 2 && time - lastScan >= 150) {
        lastScan = time;
        const scale = Math.min(1, 800 / Math.max(video.videoWidth, video.videoHeight));
        canvas.width = Math.round(video.videoWidth * scale);
        canvas.height = Math.round(video.videoHeight * scale);
        context.drawImage(video, 0, 0, canvas.width, canvas.height);
        const frame = context.getImageData(0, 0, canvas.width, canvas.height);
        const match = decode(frame.data, frame.width, frame.height);
        if (match?.data) {
          stopCamera();
          status.textContent = 'QR-код зчитано.';
          onCode(match.data);
          return;
        }
      }
      session.frame = requestAnimationFrame(scanFrame);
    }

    session.frame = requestAnimationFrame(scanFrame);
  } catch (error) {
    if (cameraSession !== session) return;
    stopCamera();
    status.textContent = error.name === 'Error'
      ? error.message
      : 'Камера недоступна. Перевірте дозвіл браузера або введіть номер вручну.';
  }
}

function renderLookup(container, onCode) {
  stopCamera();
  container.innerHTML = `
    <h1>Пошук за QR або номером</h1>
    <button class="primary full" id="camera-toggle" type="button">Увімкнути камеру</button>
    <video id="qr-camera" playsinline muted hidden style="width:100%;max-height:50vh"></video>
    <p id="camera-status" role="status"></p>
    <form id="asset-lookup">
      <label>Інвентарний номер або QR<input name="code" required autocomplete="off"></label>
      <button class="full" type="submit">Знайти</button>
    </form>`;

  const toggle = container.querySelector('#camera-toggle');
  const video = container.querySelector('#qr-camera');
  const status = container.querySelector('#camera-status');
  const form = container.querySelector('#asset-lookup');
  toggle.onclick = () => {
    if (cameraSession) {
      stopCamera();
      status.textContent = '';
      return;
    }
    scanCamera(video, toggle, status, onCode);
  };
  form.onsubmit = event => {
    event.preventDefault();
    onCode(form.elements.code.value);
  };
}

async function printAssetLabel(asset) {
  const popup = window.open('', '_blank', 'width=440,height=480');
  if (!popup) throw new Error('Дозвольте спливні вікна для друку етикетки.');
  popup.opener = null;
  popup.document.body.textContent = 'Підготовка етикетки…';

  try {
    const generate = await loadQrLibrary(
      'qrcode',
      'https://cdn.jsdelivr.net/npm/qrcode-generator@1.4.4/qrcode.js',
      'sha384-8FWZA6BGMXhsfO+BLtrJK0We6gg5o1JyO8xQm6peWDEUs17ACA5ziE/NIAkl9z2k'
    );
    if (popup.closed) return;

    const code = generate(0, 'M');
    code.addData(asset.qr_code, 'Byte');
    code.make();
    const doc = popup.document;
    doc.title = 'Stage Base · QR-етикетка';
    doc.documentElement.lang = 'uk';
    const style = doc.createElement('style');
    style.textContent = 'body{font:14px system-ui;text-align:center;margin:0;padding:4mm;overflow-wrap:anywhere}svg{width:30mm;height:30mm}button{margin:1em}@media print{button{display:none}}';
    doc.head.append(style);
    const label = doc.createElement('div');
    label.innerHTML = code.createSvgTag({ cellSize: 4, margin: 16, scalable: true });
    const number = doc.createElement('strong');
    number.textContent = asset.inventory_number;
    const name = doc.createElement('div');
    name.textContent = asset.name;
    const print = doc.createElement('button');
    print.textContent = 'Друкувати';
    print.onclick = () => popup.print();
    doc.body.replaceChildren(label, number, name, print);
    popup.focus();
  } catch (error) {
    popup.close();
    throw error;
  }
}

window.addEventListener('pagehide', stopCamera);
document.addEventListener('visibilitychange', () => {
  if (document.hidden) stopCamera();
});
