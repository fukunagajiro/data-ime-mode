// ホストに届かない理由の分類。README「動かないとき」の表と 1 対 1。
//
// 利用者から見ると、未登録も起動失敗も「欄にフォーカスしても何も起きない」
// という同じ見え方になる。切り分けはこの分類だけが持っている。
//
//   unregistered … レジストリに登録がない。connectNative は同期的に throw せず
//                  "Specified native messaging host not found." で切断する。
//   no-response  … 登録はあるが往復できない。Constrained Language Mode に
//                  阻まれた Add-Type、レジストリが指す旧フォルダに
//                  ime-host.bat が無い場合はいずれもホストが即終了するので、
//                  タイムアウトではなく切断として現れる。
//   unknown      … 上のどちらとも言い切れない。生の文字列を出す。
function classifyHostFailure(r) {
  const detail = String((r && r.detail) || '');
  const error = String((r && r.error) || '');

  if (/not found/i.test(detail)) return 'unregistered';
  if (detail || error === 'timeout' || error === 'disconnected') return 'no-response';
  return 'unknown';
}

if (typeof module !== 'undefined' && module.exports) module.exports = { classifyHostFailure };
