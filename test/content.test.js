// content.js / background.js の状態遷移を、最小限の DOM / chrome スタブ上で確認する。
// 依存なし。  node test\content.test.js
//
// IME そのものは触らないので、Win32 側の確認は test-ime-*.ps1 と
// test\test.html で別途行うこと。

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const CONTENT = process.argv[2] || path.join(__dirname, '..', 'extension', 'content.js');
const BACKGROUND = process.argv[3] || path.join(__dirname, '..', 'extension', 'background.js');

// ブラウザは未処理の reject をログに出すだけで停止しない。挙動を合わせる。
let unhandled = 0;
process.on('unhandledRejection', () => { unhandled++; });

function makeTarget(l) {
  return {
    addEventListener(t, f) { (l[t] ||= []).push(f); },
    fire(t, e) { for (const f of (l[t] || [])) f(e); },
  };
}

// data-ime-mode 属性だけを持つ要素のふり。attr が null なら属性なし。
const el = (a) => ({ getAttribute: (n) => (n === 'data-ime-mode' && a != null ? a : null) });

// sendMessage の返り方。MV3 の実機では、リスナが sendResponse を呼ばず true も
// 返さないとポートが無応答で閉じ、届いているのに Promise が reject する。
const REPLY = {
  ack:   () => Promise.resolve({ ok: true }),
  noack: () => Promise.reject(new Error('The message port closed before a response was received.')),
  dead:  () => Promise.reject(new Error('Could not establish connection. Receiving end does not exist.')),
  throw: () => { throw new Error('Extension context invalidated.'); },
};

function loadContent({ reply = 'ack', sendImpl, attr = 'hiragana', readyState = 'loading' } = {}) {
  const sent = [];
  // sent は 'prewarm' や mode 名の文字列に潰しているため、type フィールドが
  // 抜けても検知できない。生のメッセージ形をここに残し、別途ピン留めする。
  const sentRaw = [];
  const document = Object.assign(makeTarget({}), {
    visibilityState: 'visible',
    activeElement: el(null),
    hasFocus: () => document._hasFocus,
    _hasFocus: true,
    readyState,
    // prewarm の判定は属性の存在だけを見る。値の妥当性は modeOf() の仕事。
    querySelector: (sel) => (attr != null && sel === '[data-ime-mode]' ? el(attr) : null),
  });
  const window = makeTarget({});
  const chrome = {
    runtime: {
      sendMessage(m) {
        sent.push(m.prewarm ? 'prewarm' : m.mode);
        sentRaw.push(m);
        return (sendImpl || REPLY[reply])(m);
      },
    },
  };
  const ctx = { document, window, chrome, setTimeout, clearTimeout, console };
  vm.createContext(ctx);
  vm.runInContext(fs.readFileSync(CONTENT, 'utf8'), ctx);
  return { document, window, sent, sentRaw };
}

function loadBackground({ respond } = {}) {
  let listener = null;
  const posted = [];
  // connect() の「port があれば作り直さない」ガード (background.js:19) を
  // 数えるためのカウンタ。オブジェクトに包むのは、listener 呼び出しの後でも
  // 同じ参照から最新値を読めるようにするため（プリミティブ値だと呼び出し
  // 時点のコピーしか返せない）。
  const connectStats = { count: 0 };
  let onMessageHandler = null;
  const port = {
    onMessage: { addListener(fn) { onMessageHandler = fn; } },
    onDisconnect: { addListener() {} },
    postMessage(m) {
      posted.push(m);
      // 応答ハンドラが登録されていれば非同期で応答を返す
      if (respond && onMessageHandler) {
        const response = respond(m);
        if (response !== undefined) {
          // microtask として実行し、queue が処理できるようにする
          Promise.resolve().then(() => onMessageHandler(response));
        }
      }
    },
  };
  const chrome = {
    runtime: {
      connectNative: () => { connectStats.count++; return port; },
      onMessage: { addListener: (fn) => { listener = fn; } },
      lastError: null,
    },
  };
  const ctx = { chrome, setTimeout, clearTimeout, setInterval: () => 0, console, Promise };
  vm.createContext(ctx);
  vm.runInContext(fs.readFileSync(BACKGROUND, 'utf8'), ctx);
  return { listener, posted, connectStats };
}

const results = [];
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function check(name, actual, expected) {
  const ok = JSON.stringify(actual) === JSON.stringify(expected);
  results.push([name, ok, actual, expected]);
}

(async () => {
  // ---- content.js: フォーカス遷移 ------------------------------------------

  // 隣接する制御欄の行き来は 40ms のコアレス窓で 1 往復に畳まれる。
  {
    const t = loadContent();
    t.document.fire('focusin', { target: el('hiragana') });
    t.document.fire('focusout', {});
    t.document.fire('focusin', { target: el('half-katakana') });
    await sleep(80);
    check('隣接欄の移動で復帰(null)を挟まない', t.sent, ['hiragana', 'half-katakana']);
  }

  // 制御対象でない場所へ抜けたら 40ms 後に復帰。
  {
    const t = loadContent();
    t.document.fire('focusin', { target: el('katakana') });
    t.document.fire('focusout', {});
    await sleep(80);
    check('離脱で 40ms 後に復帰', t.sent, ['katakana', null]);
  }

  // Alt+Tab: タイマーを待たず即座に返す。待つと切替先の IME が汚れる。
  {
    const t = loadContent();
    t.document.fire('focusin', { target: el('hiragana') });
    t.window.fire('blur');
    check('window blur で即座に復帰', t.sent, ['hiragana', null]);

    t.document.activeElement = el('hiragana');
    t.window.fire('focus');
    check('window focus で再適用', t.sent, ['hiragana', null, 'hiragana']);
  }

  // Chromium が focus と focusin の両方を出しても二重送信しない。
  {
    const t = loadContent();
    t.document.fire('focusin', { target: el('hiragana') });
    t.window.fire('blur');
    t.document.activeElement = el('hiragana');
    t.window.fire('focus');
    t.document.fire('focusin', { target: el('hiragana') });
    check('focus と focusin の二重発火を重複排除', t.sent, ['hiragana', null, 'hiragana']);
  }

  // Edge が前面でないのに再適用すると、ホストが hwnd 0 を別アプリに解決してしまう。
  {
    const t = loadContent();
    t.document.fire('focusin', { target: el('hiragana') });
    t.window.fire('blur');
    t.document.activeElement = el('hiragana');
    t.document._hasFocus = false;
    t.document.fire('visibilitychange', {});
    check('hasFocus() が false なら再適用しない', t.sent, ['hiragana', null]);
  }

  // タブ切替でも往復すること。
  {
    const t = loadContent();
    t.document.fire('focusin', { target: el('katakana') });
    t.document.visibilityState = 'hidden';
    t.document.fire('visibilitychange', {});
    t.document.activeElement = el('katakana');
    t.document.visibilityState = 'visible';
    t.document.fire('visibilitychange', {});
    check('タブ非表示→再表示で復帰と再適用', t.sent, ['katakana', null, 'katakana']);
  }

  // 何もフォーカスされていない状態で戻ってきたら、解放したままにする。
  {
    const t = loadContent();
    t.document.fire('focusin', { target: el('hiragana') });
    t.window.fire('blur');
    t.document.activeElement = el(null);
    t.window.fire('focus');
    check('フォーカスが無い状態で戻っても何も送らない', t.sent, ['hiragana', null]);
  }

  // 未知の値は属性なしと同じ扱い。大文字・前後の空白は正規化する。
  {
    const t = loadContent();
    t.document.fire('focusin', { target: el('disabled') });
    t.document.fire('focusin', { target: el(null) });
    t.document.fire('focusin', { target: el('  HIRAGANA  ') });
    t.document.fire('focusin', { target: el('constructor') });
    check('未知の値は無視 / 大文字と空白は正規化', t.sent, ['hiragana', null]);
  }

  // ---- content.js: 事前起動 (prewarm) ----------------------------------------
  //
  // ホストの PowerShell 起動は実測 1.2 秒かかる。フォーカスしてから払うと
  // 体感の遅れになるので、対象欄を持つ文書を開いた時点で温めておく。

  {
    const t = loadContent();
    t.document.fire('DOMContentLoaded', {});
    check('属性のある文書は prewarm を送る', t.sent, ['prewarm']);

    // 本番では DOMContentLoaded は { once: true } で登録され、readyState が
    // 'complete' のときの分岐 (else prewarm()) とは互いに排他なので、
    // prewarmSent の出番 (2 回目の呼び出しを弾く) は本来来ない。ここで
    // 2 回目を発火しているのは、このスタブの addEventListener が once を
    // 無視して律儀に再度呼ぶため。つまりこの check が確かめているのは
    // 「本番で 2 通送られかけている」ことではなく、prewarmSent という
    // 防御そのものが機能していること。
    t.document.fire('DOMContentLoaded', {});
    check('prewarmSent フラグ: 想定外の再呼び出しでも送り直さない (once を無視するスタブ経由)', t.sent, ['prewarm']);
  }

  // sent は 'prewarm' や mode 名に潰しているため、type: 'ime' が抜けても
  // このテストと background の suite（自前の literal を組む）はどちらも
  // 気づけない。extension/background.js:95 の `msg.type !== 'ime'` ガードは
  // 生のメッセージ形を見て初めて壊れたことが分かるので、ここでピン留めする。
  {
    const t = loadContent();
    t.document.fire('DOMContentLoaded', {});
    check('prewarm メッセージの形: { type: "ime", prewarm: true }', t.sentRaw[0], { type: 'ime', prewarm: true });

    t.document.fire('focusin', { target: el('hiragana') });
    check(
      '適用メッセージの形: { type: "ime", mode, spec }',
      t.sentRaw[1],
      { type: 'ime', mode: 'hiragana', spec: { open: 1, conv: 'hiragana' } },
    );
  }

  // 属性を使っていないページで PowerShell を起動させない。この性質が崩れると、
  // 拡張機能を入れているだけであらゆるページでプロセスが常駐する。
  {
    const t = loadContent({ attr: null });
    t.document.fire('DOMContentLoaded', {});
    check('属性が無い文書は prewarm を送らない', t.sent, []);
  }

  // content script の実行が読み込み後になった場合も温める。
  {
    const t = loadContent({ readyState: 'complete' });
    check('読み込み済みの文書では即座に prewarm', t.sent, ['prewarm']);
  }

  // prewarm は適用ではないので currentMode を汚さない。
  {
    const t = loadContent();
    t.document.fire('DOMContentLoaded', {});
    t.document.fire('focusin', { target: el('hiragana') });
    check('prewarm の後も適用は送られる', t.sent, ['prewarm', 'hiragana']);
  }

  // prewarm の失敗で forget() を呼ぶと currentMode が UNKNOWN になり、同じモードが
  // 二重に送られる。prewarm の失敗は捨てるだけであることの裏取り。prewarm が応答
  // する前にユーザーが欄へフォーカスした場合をシミュレートする。
  {
    let rejectPrewarm;
    let n = 0;
    const t = loadContent({
      sendImpl: () => (++n === 1 ? new Promise((_, rej) => { rejectPrewarm = rej; }) : REPLY.ack()),
    });
    t.document.fire('DOMContentLoaded', {});
    // prewarm は送られたが、まだ応答しない状態
    t.document.fire('focusin', { target: el('hiragana') });
    await sleep(10);
    // ここで prewarm の失敗が届く。currentMode は 'hiragana' で上書きされている。
    rejectPrewarm(new Error('late'));
    await sleep(10);
    // 同じモードで再度フォーカスしても、forget() が呼ばれていなければ送らない。
    // forget() が呼ばれていれば currentMode が UNKNOWN になり、ここで再送される。
    t.document.fire('focusin', { target: el('hiragana') });
    check('prewarm が失敗しても適用は 1 回だけ', t.sent, ['prewarm', 'hiragana']);
  }

  // ---- content.js: 送信が失敗したときの回復 --------------------------------
  //
  // 送信の失敗が「離脱時の復帰」を握り潰すと、IME が他アプリまで汚染されたまま
  // 取り残される。これがこの拡張機能で最も避けたい壊れ方なので、reject の
  // 種類を問わず復帰は必ず送られること。

  for (const reply of ['noack', 'dead']) {
    const t = loadContent({ reply });
    t.document.fire('focusin', { target: el('hiragana') });
    await sleep(10);            // reject が microtask で届く
    t.window.fire('blur');
    check(`送信が reject (${reply}) しても離脱時の復帰は送る`, t.sent, ['hiragana', null]);
  }

  {
    const t = loadContent({ reply: 'throw' });
    t.document.fire('focusin', { target: el('hiragana') });
    t.window.fire('blur');
    check('送信が同期 throw しても離脱時の復帰は送る', t.sent, ['hiragana', null]);
  }

  // 失敗した後は「適用済み」の記憶を捨て、同じモードでも再送できること。
  {
    let fail = true;
    const t = loadContent({ sendImpl: () => (fail ? REPLY.dead() : REPLY.ack()) });
    t.document.fire('focusin', { target: el('hiragana') });
    await sleep(10);
    fail = false;
    t.document.fire('focusin', { target: el('hiragana') });
    check('失敗の後に同じモードを再送できる', t.sent, ['hiragana', 'hiragana']);
  }

  // 正常時は重複排除が効いていること（上の回復が緩すぎないことの裏取り）。
  {
    const t = loadContent();
    t.document.fire('focusin', { target: el('hiragana') });
    await sleep(10);
    t.document.fire('focusin', { target: el('hiragana') });
    check('成功時は同じモードを再送しない', t.sent, ['hiragana']);
  }

  // 遅れて届いた失敗が、その後に適用した新しいモードを消してはいけない。
  {
    let rejectFirst;
    let n = 0;
    const t = loadContent({
      sendImpl: () => (++n === 1 ? new Promise((_, rej) => { rejectFirst = rej; }) : REPLY.ack()),
    });
    t.document.fire('focusin', { target: el('hiragana') });
    t.document.fire('focusin', { target: el('katakana') });
    rejectFirst(new Error('late'));
    await sleep(10);
    t.document.fire('focusin', { target: el('katakana') });
    check('遅れて届いた失敗が新しい状態を消さない', t.sent, ['hiragana', 'katakana']);
  }

  // ---- background.js: connect() の単一プロセス化ガード ----------------------
  //
  // extension/background.js:19 の `if (port) return port;` だけが、ナビゲーション
  // のたびに（しかもフレームごとに）PowerShell を 1 プロセスずつ起動するのを
  // 防いでいる。README は「プロセスが起動するのは最初の 1 回だけで、2 回目
  // 以降は ping の往復（~1ms）で終わる」と約束しているので、ここが崩れると
  // ドキュメント違反になる上、prewarm 導入前は 1 セッションに 1 回しか
  // connect() を通らなかったのが、今は属性を持つページを開くたび（全フレーム）
  // に通るようになっている。
  {
    // モジュールを読み込んだだけでは、誰も connect() を呼ばない。
    const { connectStats } = loadBackground();
    check('background 読み込みだけでは connectNative を呼ばない', connectStats.count, 0);
  }
  {
    // queue は直列実行なので、1 通目の call() が解決しないと 2 通目の
    // connect() は走らない。応答を返さないと 1 通目は 3 秒のタイムアウト
    // まで解決しないため、実機同様にすぐ ping 応答を返す必要がある。
    const { listener, connectStats } = loadBackground({
      respond: (m) => (m.cmd === 'ping' ? { id: m.id, ok: true } : undefined),
    });
    listener({ type: 'ime', prewarm: true }, {}, () => {});
    await sleep(10);
    listener({ type: 'ime', prewarm: true }, {}, () => {});
    await sleep(10);
    check('prewarm を 2 回送っても connectNative は 1 回だけ (単一プロセス化ガード)', connectStats.count, 1);
  }

  // ---- background.js: 受領の応答 -------------------------------------------
  //
  // 応答しないとポートが無応答で閉じ、content 側の Promise が reject する。
  // 「届いた」と「届かなかった」が区別できなくなる根本原因なので、ここで止める。
  {
    const { listener, posted } = loadBackground();

    let responded = false;
    listener(
      { type: 'ime', mode: 'hiragana', spec: { open: 1, conv: 'hiragana' } },
      {},
      () => { responded = true; },
    );
    check('background が受領を同期的に応答する', responded, true);

    let respondedOnRelease = false;
    listener({ type: 'ime', mode: null, spec: null }, {}, () => { respondedOnRelease = true; });
    check('background が復帰要求にも応答する', respondedOnRelease, true);

    await sleep(10);
    check('background がホストへ set を送る', posted.length > 0 && posted[0].cmd, 'set');
  }

  // ---- background.js: prewarm を独立したコンテキストでテスト ----
  // (acquire/release で queue がブロックされないように)
  {
    const { listener, posted } = loadBackground();

    let respondedPrewarm = false;
    listener({ type: 'ime', prewarm: true }, {}, () => { respondedPrewarm = true; });
    check('background が prewarm に応答する', respondedPrewarm, true);
    await sleep(10);
    check('background が prewarm を ping にする', posted.map((m) => m.cmd), ['ping']);
  }

  // ---- background.js: 危険な経路: saved を保持中に prewarm が届く場合 ----
  // ポートが応答を返すので acquire が完了し saved が確立される。
  // その後 prewarm を送ると、修正前はここで release() が走って restore set が飛ぶ。
  // 修正後は prewarm の分岐で ping になっているはず。
  {
    const { listener, posted } = loadBackground({
      respond: (m) => {
        if (m.cmd === 'set') {
          // acquire/release の set に応答。hwnd と previous を返す。
          return { id: m.id, ok: true, hwnd: 1, previous: 0, previousConv: 0x19 };
        }
      },
    });

    // spec あり: acquire を実行して saved を確立する
    let respondedAcquire = false;
    listener(
      { type: 'ime', mode: 'hiragana', spec: { open: 1, conv: 'hiragana' } },
      {},
      () => { respondedAcquire = true; },
    );
    check('background が acquire に応答する', respondedAcquire, true);

    // queue に set が投稿されるのを待つ
    await sleep(50);

    // saved が確立された状態で prewarm を送る
    posted.length = 0;
    let respondedPrewarm = false;
    listener({ type: 'ime', prewarm: true }, {}, () => { respondedPrewarm = true; });
    check('background が saved 保持中の prewarm に応答する', respondedPrewarm, true);

    await sleep(10);
    check('saved 保持中の prewarm は ping である (restore set ではない)', posted.map((m) => m.cmd), ['ping']);
  }

  // ---- 結果 ----------------------------------------------------------------

  let bad = 0;
  for (const [name, ok, actual, expected] of results) {
    console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}`);
    if (!ok) {
      bad++;
      console.log(`        期待: ${JSON.stringify(expected)}`);
      console.log(`        実際: ${JSON.stringify(actual)}`);
    }
  }
  if (unhandled) console.log(`\n未処理の reject: ${unhandled} 件`);
  console.log(`\n${results.length - bad}/${results.length} passed`);
  process.exit(bad || unhandled ? 1 : 0);
})();
