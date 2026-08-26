// Owns the native port and the "what did we change, and to what" bookkeeping.
// The host is stateless apart from its own crash-safety restore.

const HOST_NAME = 'io.github.fukunagajiro.data_ime_mode';
const KEEPALIVE_MS = 20000;

let port = null;
let seq = 0;
const waiters = new Map();

// ポートが切れた理由。ホスト未登録なら connectNative は同期的に throw せず、
// "Specified native messaging host not found." で切断する。popup の診断は
// この文字列がないと「登録されていない」と「起動したが応答しない」を区別できない。
let lastDisconnect = null;

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
    lastDisconnect = err ? err.message : null;
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

  // popup からの疎通確認。ホストへ実際に ping を通し、結果を非同期に返す。
  // ここだけ true を返してチャネルを開けたままにする。下の 'ime' 側は
  // 受領を同期的に返す必要があるので（README 「送信に失敗したとき」①）、
  // リスナ全体を async にはしない。
  if (msg.probe) {
    enqueue(() =>
      call({ cmd: 'ping' }).then((r) => {
        if (r && r.ok) sendResponse({ ok: true });
        else sendResponse({ ok: false, error: (r && r.error) || 'unknown', detail: lastDisconnect });
      })
    );
    return true;
  }

  // prewarm は spec の判定より前に処理する。spec を持たないメッセージは
  // release として扱われるので、後ろに置くとページを開くたびに解放が走る。
  // ping はホスト側でウィンドウ解決も IME 操作もせず即返るので、ポートを
  // 開けてプロセスを起こすだけで済む。
  if (msg.prewarm) {
    enqueue(() => call({ cmd: 'ping' }));
    sendResponse({ ok: true });
    return;
  }

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

// Edge の起動時点で温める。属性付きページを開いた時では、autofocus された
// 対象欄には間に合わない（フォーカスと prewarm が同じ瞬間に起きる）。
chrome.runtime.onStartup.addListener(() => enqueue(() => call({ cmd: 'ping' })));
