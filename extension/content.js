// Watches focus movement and reports the desired IME state of the focused field.
// The attribute is only a marker; all actual IME manipulation happens in the host.

const ATTR = 'data-ime-mode';

// open: IME 開閉状態 / conv: 変換モード (null = 変えない)
const MODES = {
  'inactive':      { open: 0, conv: null },
  'active':        { open: 1, conv: null },
  'hiragana':      { open: 1, conv: 'hiragana' },
  'katakana':      { open: 1, conv: 'full-katakana' },
  'full-katakana': { open: 1, conv: 'full-katakana' },
  'half-katakana': { open: 1, conv: 'half-katakana' },
};

// Coalescing window for focusout -> focusin. Without it, moving between two
// controlled fields would restore and re-apply, causing a visible flicker.
const RELEASE_DELAY_MS = 40;

let currentMode = null;
let releaseTimer = null;

function modeOf(el) {
  if (!el || typeof el.getAttribute !== 'function') return null;
  const raw = el.getAttribute(ATTR);
  if (raw === null) return null;
  const v = raw.trim().toLowerCase();
  return Object.prototype.hasOwnProperty.call(MODES, v) ? v : null;
}

function apply(mode) {
  if (mode === currentMode) return;
  currentMode = mode;
  try {
    chrome.runtime.sendMessage({ type: 'ime', mode, spec: mode ? MODES[mode] : null });
  } catch {
    // Service worker gone / extension reloading. The host restores on port close.
  }
}

function cancelRelease() {
  if (releaseTimer !== null) {
    clearTimeout(releaseTimer);
    releaseTimer = null;
  }
}

document.addEventListener('focusin', (e) => {
  cancelRelease();
  apply(modeOf(e.target));
}, true);

document.addEventListener('focusout', () => {
  cancelRelease();
  releaseTimer = setTimeout(() => {
    releaseTimer = null;
    apply(null);
  }, RELEASE_DELAY_MS);
}, true);

// Edge 自体がフォアグラウンドを失った / タブが隠れた場合は必ず元に戻す。
// これを怠ると他アプリを操作中に IME が変更されたまま取り残される。
function releaseNow() {
  cancelRelease();
  apply(null);
}

window.addEventListener('blur', releaseNow);
window.addEventListener('pagehide', releaseNow);
document.addEventListener('visibilitychange', () => {
  if (document.visibilityState === 'hidden') releaseNow();
});
