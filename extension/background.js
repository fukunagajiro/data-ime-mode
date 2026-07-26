// Owns the native port and the "what did we change, and to what" bookkeeping.
// The host is stateless apart from its own crash-safety restore.

const HOST_NAME = 'com.example.data_ime_mode';
const KEEPALIVE_MS = 20000;

let port = null;
let seq = 0;
const waiters = new Map();

// The window we touched and the IME state it had before we touched it.
let saved = null; // { hwnd, open, conv }

// Requests are serialized: focus events arrive faster than the round trip,
// and out-of-order set/restore would leave the IME in the wrong state.
let queue = Promise.resolve();

function connect() {
  if (port) return port;

  port = chrome.runtime.connectNative(HOST_NAME);

  port.onMessage.addListener((msg) => {
    const resolve = waiters.get(msg.id);
    if (resolve) {
      waiters.delete(msg.id);
      resolve(msg);
    }
  });

  port.onDisconnect.addListener(() => {
    const err = chrome.runtime.lastError;
    if (err) console.warn('[data-ime-mode] native host disconnected:', err.message);
    port = null;
    saved = null;
    for (const resolve of waiters.values()) resolve({ ok: false, error: 'disconnected' });
    waiters.clear();
  });

  return port;
}

function call(req) {
  return new Promise((resolve) => {
    let p;
    try {
      p = connect();
    } catch (e) {
      resolve({ ok: false, error: String(e) });
      return;
    }
    const id = ++seq;
    waiters.set(id, resolve);
    setTimeout(() => {
      if (waiters.delete(id)) resolve({ ok: false, error: 'timeout' });
    }, 3000);
    try {
      p.postMessage({ ...req, id });
    } catch (e) {
      waiters.delete(id);
      resolve({ ok: false, error: String(e) });
    }
  });
}

async function release() {
  if (!saved) return;
  const s = saved;
  saved = null;
  await call({ cmd: 'set', open: s.open, convRaw: s.conv, hwnd: s.hwnd, restore: true });
}

async function acquire(spec) {
  if (saved) {
    // Already holding this window; just retarget it, keeping the originally
    // captured state so the eventual restore is still correct.
    await call({ cmd: 'set', open: spec.open, conv: spec.conv, hwnd: saved.hwnd });
    return;
  }

  const r = await call({ cmd: 'set', open: spec.open, conv: spec.conv, hwnd: 0 });
  if (r && r.ok) {
    saved = { hwnd: r.hwnd, open: r.previous, conv: r.previousConv };
  } else if (r) {
    console.warn('[data-ime-mode]', r.error);
  }
}

function enqueue(fn) {
  queue = queue.then(fn).catch((e) => console.warn('[data-ime-mode]', e));
  return queue;
}

chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  if (!msg || msg.type !== 'ime') return;
  enqueue(() => (msg.spec ? acquire(msg.spec) : release()));
  // 受領だけを即座に返す。応答しないとポートが無応答のまま閉じ、送信側の
  // Promise が reject するため、content.js から「届いた」と「届かなかった」が
  // 区別できなくなる。実際の適用は queue 上で進むので完了は待たない。
  sendResponse({ ok: true });
});

// An open native port keeps the service worker alive, but a periodic message
// makes that explicit rather than relying on eviction heuristics.
setInterval(() => {
  if (port) call({ cmd: 'ping' });
}, KEEPALIVE_MS);
