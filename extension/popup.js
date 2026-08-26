// ホストへ実際に ping を通し、届かない理由まで出す。
// 未登録・レジストリが旧フォルダを指したまま・Constrained Language Mode で
// Add-Type が塞がれている、は利用者から見て同じ「何も起きない」に見えるので、
// ここで切り分けられないと切り分ける場所がない。

const HOST_NAME = 'io.github.fukunagajiro.data_ime_mode';

const statusEl = document.getElementById('status');
const detailEl = document.getElementById('detail');

document.getElementById('hostname').textContent = HOST_NAME;
document.getElementById('extid').textContent = chrome.runtime.id;

function show(cls, text, detailHtml) {
  statusEl.className = cls;
  statusEl.textContent = text;
  detailEl.textContent = '';
  if (detailHtml) detailEl.append(detailHtml);
}

function para(...nodes) {
  const f = document.createDocumentFragment();
  f.append(...nodes);
  return f;
}

function code(text) {
  const c = document.createElement('code');
  c.textContent = text;
  return c;
}

function explain(r) {
  const raw = String((r && r.detail) || (r && r.error) || '');

  switch (classifyHostFailure(r)) {
    case 'unregistered':
      return para(
        'ホストが登録されていません。',
        document.createElement('br'),
        code('powershell -ExecutionPolicy Bypass -File host\install.ps1'),
        ' を実行し、Edge を完全に終了してから起動し直してください。'
      );
    case 'no-response':
      return para(
        'ホストは登録されていますが往復できません（',
        code(raw || 'disconnected'),
        '）。フォルダを移動したのに ',
        code('install.ps1'),
        ' を再実行していない（レジストリが旧フォルダを指したまま）か、',
        'PowerShell の Constrained Language Mode（AppLocker / WDAC）や EDR が ',
        code('Add-Type'),
        ' の P/Invoke を止めている可能性があります。',
        code('host\debug.on'),
        ' を置くと ',
        code('host\debug.log'),
        ' に記録が残ります。'
      );
    default:
      return para('ホストからの応答がありません: ', code(raw || 'unknown'));
  }
}

function check() {
  show('wait', '確認中…');
  chrome.runtime.sendMessage({ type: 'ime', probe: true }, (r) => {
    if (chrome.runtime.lastError) {
      show('ng', '× 拡張機能に接続できません', para(chrome.runtime.lastError.message));
      return;
    }
    if (r && r.ok) show('ok', '✓ ネイティブホストに接続できています');
    else show('ng', '× ネイティブホストに接続できません', explain(r));
  });
}

document.getElementById('recheck').addEventListener('click', check);
check();
