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

// null は「解放済み」を意味するので、送信できたか分からない状態はこれで表す。
// null ともどのモード名とも一致しないため、次が適用でも復帰でも必ず送り直される。
// 失敗を null に潰すと、離脱時の apply(null) が重複排除で消えて IME が
// 他アプリまで汚染されたまま取り残される。
const UNKNOWN = Symbol('unknown');

let currentMode = null;
let releaseTimer = null;

function modeOf(el) {
  if (!el || typeof el.getAttribute !== 'function') return null;
  const raw = el.getAttribute(ATTR);
  if (raw === null) return null;
  const v = raw.trim().toLowerCase();
  return Object.prototype.hasOwnProperty.call(MODES, v) ? v : null;
}

// The send did not land, so we must not keep claiming the mode is applied -
// apply()'s dedupe would swallow every retry. Only clear if nothing newer has
// been applied in the meantime.
function forget(mode) {
  if (currentMode === mode) currentMode = UNKNOWN;
}

function apply(mode) {
  if (mode === currentMode) return;
  currentMode = mode;
  try {
    // Extension context invalidated (reload/disable) throws synchronously;
    // a service worker that cannot be reached rejects the returned promise.
    // background.js answers every message, so a rejection really means the
    // message did not arrive - not merely that nobody replied.
    const sent = chrome.runtime.sendMessage({ type: 'ime', mode, spec: mode ? MODES[mode] : null });
    if (sent && typeof sent.catch === 'function') sent.catch(() => forget(mode));
  } catch {
    // The host restores the IME on port close, so nothing is stranded.
    forget(mode);
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

// ...and re-apply on the way back, since the field is still focused but the
// mode was dropped on the way out. Symmetric with releaseNow: blur restored the
// pre-focus state, so this is not stomping a choice the user made in the field.
//
// hasFocus() guards against re-applying while Edge is not the foreground app -
// the host resolves hwnd 0 to the foreground window and would touch someone else.
function reapplyNow() {
  if (!document.hasFocus()) return;
  cancelRelease();
  apply(modeOf(document.activeElement));
}

window.addEventListener('blur', releaseNow);
window.addEventListener('focus', reapplyNow);
window.addEventListener('pagehide', releaseNow);
document.addEventListener('visibilitychange', () => {
  if (document.visibilityState === 'hidden') releaseNow();
  else reapplyNow();
});
