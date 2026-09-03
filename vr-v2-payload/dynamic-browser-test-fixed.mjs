import { spawn } from 'node:child_process';
import { writeFile } from 'node:fs/promises';
import { setTimeout as delay } from 'node:timers/promises';
import { fileURLToPath } from 'node:url';

const baseUrl = process.env.VR_V2_BASE_URL ?? 'http://127.0.0.1:4173/';
const browserResult = process.env.VR_V2_BROWSER_RESULT
  ?? fileURLToPath(new URL('../validation/browser-dynamic.json', import.meta.url));
const chrome = findChrome();
const errors = [];
const downloads = [];
let assertions = 0;

class CDP {
  constructor(ws) {
    this.ws = ws;
    this.nextId = 1;
    this.pending = new Map();
    this.events = [];
    ws.addEventListener('message', (event) => {
      const message = JSON.parse(typeof event.data === 'string' ? event.data : String(event.data));
      if (message.id) {
        const pending = this.pending.get(message.id);
        if (!pending) return;
        if (message.error) pending.reject(new Error(message.error.message));
        else pending.resolve(message.result);
        this.pending.delete(message.id);
      } else {
        this.events.push(message);
      }
    });
  }

  send(method, params = {}) {
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`CDP 命令超时: ${method}`));
      }, 20000);
      this.pending.set(id, {
        resolve: (value) => {
          clearTimeout(timer);
          resolve(value);
        },
        reject: (error) => {
          clearTimeout(timer);
          reject(error);
        },
      });
      this.ws.send(JSON.stringify({ id, method, params }));
    });
  }
}

const chromeProcess = spawn(chrome, [
  '--headless=new',
  '--disable-gpu',
  '--no-sandbox',
  '--disable-dev-shm-usage',
  '--remote-debugging-port=9222',
  '--user-data-dir=/tmp/vr-v2-chrome-profile',
  'about:blank',
], { stdio: ['ignore', 'pipe', 'pipe'] });

chromeProcess.stderr.on('data', () => undefined);
chromeProcess.stdout.on('data', () => undefined);

const target = await waitForTarget();
const ws = new WebSocket(target.webSocketDebuggerUrl);
await onceOpen(ws);
const cdp = new CDP(ws);
await cdp.send('Page.enable');
await cdp.send('Runtime.enable');
await cdp.send('Log.enable');
await cdp.send('Page.setDownloadBehavior', { behavior: 'allowAndName', downloadPath: '/tmp/vr-v2-downloads', eventsEnabled: true }).catch(() => undefined);
ws.addEventListener('message', (event) => {
  const message = JSON.parse(typeof event.data === 'string' ? event.data : String(event.data));
  if (message.method === 'Runtime.exceptionThrown') {
    errors.push(message.params.exceptionDetails.text);
  }
  if (message.method === 'Log.entryAdded' && ['error', 'warning'].includes(message.params.entry.level)) {
    errors.push(message.params.entry.text);
  }
  if (message.method?.startsWith('Page.download')) downloads.push(message);
});

await cdp.send('Page.navigate', { url: baseUrl });
await waitForReady(cdp);
await cdp.send('Emulation.setDeviceMetricsOverride', { width: 1440, height: 1000, deviceScaleFactor: 1, mobile: false });
await delay(250);

const initial = await evaluate(cdp, `(() => {
  const api = window.__VR_STORYBOARD_TEST__;
  return {
    ready: Boolean(api),
    bodyChildren: document.body.children.length,
    status: document.querySelector('#status-selection')?.textContent,
    canvas: Boolean(document.querySelector('canvas')),
    humanoids: api?.humanoids?.(),
    shotCount: api?.shotCount?.(),
    camera: api?.cameraState?.(),
    errorText: document.querySelector('#error-screen')?.textContent ?? '',
  };
})()`);

check(initial.ready, '测试 API 应存在');
check(initial.bodyChildren > 0 && initial.canvas, '页面应正常加载且非白屏');
check(initial.humanoids?.A && initial.humanoids?.B, '蓝色人物 A 与红色人物 B 应存在');
check(initial.humanoids.A.color === 0x2f78d4, '人物 A 颜色应为蓝色');
check(initial.humanoids.B.color === 0xd34b4b, '人物 B 颜色应为红色');
check(initial.shotCount >= 1, '默认至少有一个分镜');

const interactions = await evaluate(cdp, `(async () => {
  const api = window.__VR_STORYBOARD_TEST__;
  const before = api.snapshot();
  const selected = api.select('char-a-control-left-hand-target');
  api.moveControl('A', 'left-hand-target', [0.12, 0.08, -0.04]);
  api.moveControl('A', 'right-foot-target', [0.04, 0.05, 0.06]);
  api.applyPose('A', 'forward-lean');
  const after = api.snapshot();
  const wall = api.addProp('wall');
  const bed = api.addProp('bed');
  const newShot = api.newShot();
  const duplicated = api.duplicateShot();
  api.previousShot();
  api.nextShot();
  api.setGhost(true, 0.3);
  const cameraBefore = api.cameraState();
  api.setCameraFocal(70);
  api.setCameraAspect('1:1');
  api.setCameraPip(true);
  api.focusCamera('midpoint');
  const cameraAfter = api.cameraState();
  return {
    selected,
    handMoved: before.a.controls['left-hand-target'].position.join(',') !== after.a.controls['left-hand-target'].position.join(','),
    footMoved: before.a.controls['right-foot-target'].position.join(',') !== after.a.controls['right-foot-target'].position.join(','),
    wall,
    bed,
    newShot,
    duplicated,
    shotCount: api.shotCount(),
    activeShotId: api.activeShotId(),
    ghost: api.ghostState(),
    cameraBefore,
    cameraAfter,
  };
})()`);

check(interactions.selected, '应可选择人物控制点');
check(interactions.handMoved, '应可移动手部控制点并更新 IK');
check(interactions.footMoved, '应可移动脚部控制点并更新 IK');
check(interactions.wall && interactions.bed, '应可添加墙和床');
check(interactions.newShot && interactions.duplicated, '应可新建并复制分镜');
check(interactions.shotCount >= 3, '分镜数量应增加');
check(interactions.ghost.enabled && Math.abs(interactions.ghost.opacity - 0.3) < 1e-6, '上一镜残影应可开启并调节透明度');
check(interactions.cameraAfter.focalLength === 70, '摄影机焦距应可改为 70mm');
check(interactions.cameraAfter.aspectRatio === '1:1', '摄影机画幅应可改为 1:1');
check(interactions.cameraAfter.pipEnabled, '摄影机画中画应可开启');

const png = await evaluate(cdp, `(async () => {
  const api = window.__VR_STORYBOARD_TEST__;
  const result = await api.exportPng({ width: 1024, height: 1024, download: false, overlays: true });
  return { width: result.width, height: result.height, dataUrl: result.dataUrl.slice(0, 64), bytes: result.bytes };
})()`);
check(png.width === 1024 && png.height === 1024, 'PNG 尺寸应为 1024×1024');
check(png.dataUrl.startsWith('data:image/png;base64,iVBORw0KGgo'), 'PNG 应具有正确文件头');
check(png.bytes > 1000, 'PNG 不应为空白或空文件');

const contacts = await evaluate(cdp, `(() => {
  const api = window.__VR_STORYBOARD_TEST__;
  const created = api.createContact('head-on-shoulder', 'B', 'head', 'A', 'right-shoulder');
  const before = api.contactCount();
  const removed = created ? api.removeContact(created.id) : false;
  const after = api.contactCount();
  return { created: Boolean(created), before, removed, after };
})()`);
check(contacts.created && contacts.before >= 1, '应可建立双人接触约束');
check(contacts.removed && contacts.after === contacts.before - 1, '应可解除接触约束');

const persistence = await evaluate(cdp, `(async () => {
  const api = window.__VR_STORYBOARD_TEST__;
  const json = api.exportProjectJson();
  const project = JSON.parse(json);
  const saved = await api.saveProject();
  return { schemaVersion: project.schemaVersion, shots: project.shots.length, saved, projectId: project.projectId };
})()`);
check(persistence.schemaVersion === 2, '导出的项目 JSON schemaVersion 应为 2');
check(persistence.shots >= 3, '项目 JSON 应包含完整分镜序列');
check(persistence.saved, '项目应可保存到本地存储');

await cdp.send('Page.reload', { ignoreCache: true });
await waitForReady(cdp);
const reload = await evaluate(cdp, `(async () => {
  const api = window.__VR_STORYBOARD_TEST__;
  const loaded = await api.loadLatest();
  return { loaded, shotCount: api.shotCount(), projectId: api.projectId() };
})()`);
check(reload.loaded, '刷新后应可读取最近项目');
check(reload.shotCount >= 3, '读取后分镜数量应保持');
check(reload.projectId === persistence.projectId, '读取后项目 ID 应一致');

const pageErrors = errors.filter((text) => !text.includes('WebXR 不受支持'));
check(pageErrors.length === 0, `页面不应出现模块或运行错误: ${pageErrors.join(' | ')}`);

const result = {
  passed: true,
  assertions,
  initial,
  interactions,
  png: { width: png.width, height: png.height, bytes: png.bytes },
  contacts,
  persistence,
  reload,
  pageErrors,
  downloadEvents: downloads.length,
  chrome,
  testedAt: new Date().toISOString(),
};
await writeFile(browserResult, JSON.stringify(result, null, 2));
console.log(JSON.stringify(result, null, 2));
cdp.send('Browser.close').catch(() => undefined);
await new Promise((resolve) => setTimeout(resolve, 500));
cdp.ws.close();
chromeProcess.kill('SIGTERM');
process.exit(0);

function check(value, message) {
  assertions += 1;
  if (!value) throw new Error(message);
}

function evaluate(client, expression) {
  return client.send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true })
    .then((result) => {
      if (result.exceptionDetails) throw new Error(result.exceptionDetails.text);
      return result.result.value;
    });
}

function findChrome() {
  const candidates = [
    process.env.CHROME_PATH,
    '/usr/bin/google-chrome',
    '/usr/bin/google-chrome-stable',
    '/usr/bin/chromium',
    '/usr/bin/chromium-browser',
    '/opt/google/chrome/chrome',
  ].filter(Boolean);
  const { existsSync } = requireFs();
  const found = candidates.find((path) => existsSync(path));
  if (!found) throw new Error('未找到可用于动态验收的 Chrome/Chromium');
  return found;
}

function requireFs() {
  const require = (awaitImportMetaRequire ?? ((specifier) => {
    throw new Error(`无法加载 ${specifier}`);
  }));
  return require('node:fs');
}

const awaitImportMetaRequire = (() => {
  try {
    return eval('require');
  } catch {
    return null;
  }
})();

async function waitForTarget() {
  for (let index = 0; index < 100; index += 1) {
    try {
      const response = await fetch('http://127.0.0.1:9222/json');
      const targets = await response.json();
      const page = targets.find((item) => item.type === 'page');
      if (page) return page;
    } catch {
      // Chrome 尚未准备完成。
    }
    await delay(100);
  }
  throw new Error('Chrome DevTools 端口未就绪');
}

function onceOpen(socket) {
  return new Promise((resolve, reject) => {
    socket.addEventListener('open', resolve, { once: true });
    socket.addEventListener('error', reject, { once: true });
  });
}

async function waitForReady(client) {
  for (let index = 0; index < 200; index += 1) {
    const ready = await evaluate(client, `Boolean(window.__VR_STORYBOARD_TEST__?.ready?.())`)
      .catch(() => false);
    if (ready) return;
    await delay(100);
  }
  throw new Error('应用初始化超时');
}
