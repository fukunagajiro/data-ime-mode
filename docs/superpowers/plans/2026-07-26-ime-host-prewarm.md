# ネイティブホストの事前起動（prewarm）実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `data-ime-mode` 属性を含む文書を開いた時点でネイティブホストを起動しておき、初回フォーカス時の 1.2 秒の待ちを消す。

**Architecture:** content.js が読み込み完了後に属性の有無を 1 回調べ、見つかったら `{ type: 'ime', prewarm: true }` を 1 通送る。background.js はそれを `spec` の判定より前に受けて `{ cmd: 'ping' }` を投げるだけ。ホストは `ping` を即返し、ウィンドウ解決も IME 操作もしないので、温めるだけで状態は動かない。

**Tech Stack:** MV3 拡張機能（素の JavaScript、ビルドなし）、PowerShell 5.1 のネイティブホスト、テストは Node の `vm` と PowerShell のみ（依存パッケージなし）。

設計: `docs/superpowers/specs/2026-07-26-ime-host-prewarm-design.md`

## Global Constraints

- 依存パッケージを増やさない。テストは `node` と `powershell` だけで動くこと。
- **属性を使っていないページでは PowerShell を 1 度も起動しない**という性質を壊さない。
- prewarm は `currentMode` に触らない。失敗しても `forget()` を呼ばない。
- コメントは「なぜ」を日本語で書く。既存ファイルの書き方に合わせる。
- `content.test.js` と `host.test.ps1` は IME に一切触らない。実機に触るのは `host.e2e.ps1` だけ。
- テストコマンド:
  - `node test\content.test.js`
  - `powershell -ExecutionPolicy Bypass -File test\host.test.ps1`
  - `powershell -ExecutionPolicy Bypass -File test\host.e2e.ps1`

## File Structure

- `extension/background.js` — prewarm メッセージを `ping` に変換する分岐を追加（Task 1）
- `extension/content.js` — 属性を調べて prewarm を送る（Task 2）
- `test/content.test.js` — 上記 2 つのテスト。スタブに `readyState` / `querySelector` を追加（Task 1, 2）
- `test/host.e2e.ps1` — 「ping だけ送ってポートを閉じても IME は変わらない」を追加（Task 3）
- `README.md` — 起動タイミングの記述を修正し、実測値を根拠として載せる（Task 4）

**Task 1 を先にやる理由**: 先に content.js から prewarm を送ると、その時点の background.js は `spec` を持たないメッセージを「解放」として扱うため、ページを開くたびに release が走る中間状態ができる。受け手を先に用意する。

---

### Task 1: background.js が prewarm を ping に変換する

**Files:**
- Modify: `extension/background.js:94-101`
- Test: `test/content.test.js`（`---- background.js: 受領の応答 ----` セクションの直後に追加）

**Interfaces:**
- Consumes: 既存の `call(req)`、`enqueue(fn)`、`connect()`
- Produces: `{ type: 'ime', prewarm: true }` を受け付けるリスナ。Task 2 の content.js がこの形で送る。

- [ ] **Step 1: 失敗するテストを書く**

> **実行時の訂正（2026-07-26）**: 当初この Step は「既存の background.js テストブロック内に
> 追加する」と書いていたが、**それでは実装が正しくてもテストが落ちる**。既存ブロックでは
> 先に送られた `set` の `acquire()` が、応答を返さないポートのモックを待って直列キューを
> 塞ぐため、`call()` の 3 秒タイムアウトまで prewarm の `ping` が post されない。
> 独立した `vm` コンテキストのブロックを、既存ブロックの**後ろ**に作ること。
> スカフォールドが重複するので、`loadContent()` に倣って `loadBackground()` を作り、
> 既存ブロックと共用する。判別力は変わらない（`if (msg.prewarm)` を外すと `release()` に
> 落ち、`posted` が空のままで落ちる）。

以下は当初の記述（配置だけが上記のとおり変わる）。`listener` と `posted` がスコープにある場所に置く:

```js
    // prewarm は spec を持たない。spec の判定より前に分岐しないと release として
    // 扱われ、ページを開くたびに解放が走る。ping になっていることで裏を取る。
    posted.length = 0;
    let respondedPrewarm = false;
    listener({ type: 'ime', prewarm: true }, {}, () => { respondedPrewarm = true; });
    check('background が prewarm に応答する', respondedPrewarm, true);
    await sleep(10);
    check('background が prewarm を ping にする', posted.map((m) => m.cmd), ['ping']);
```

- [ ] **Step 2: 落ちることを確認する**

Run: `node test\content.test.js`
Expected: FAIL。`background が prewarm を ping にする` が
`期待: ["ping"] / 実際: []` になる（現状の `release()` は `saved` が無いので何も送らない）。
`background が prewarm に応答する` は現状のコードでも通る。

- [ ] **Step 3: 実装する**

`extension/background.js` のリスナを次に置き換える:

```js
chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  if (!msg || msg.type !== 'ime') return;

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
```

- [ ] **Step 4: 通ることを確認する**

Run: `node test\content.test.js`
Expected: PASS（20/20）

- [ ] **Step 5: commit**

```bash
git add extension/background.js test/content.test.js
git commit -m "background: prewarm メッセージを ping に変換する"
```

---

### Task 2: content.js が属性のある文書で prewarm を送る

**Files:**
- Modify: `extension/content.js`（`UNKNOWN` の定義の後に関数を追加、ファイル末尾に登録を追加）
- Modify: `test/content.test.js`（`loadContent` のスタブ拡張と、新しいセクションの追加）
- Test: `test/content.test.js`

**Interfaces:**
- Consumes: Task 1 の `{ type: 'ime', prewarm: true }` リスナ、既存の `ATTR`
- Produces: なし（content.js の内部関数）

- [ ] **Step 1: テストのスタブを prewarm に対応させる**

`test/content.test.js` の `loadContent` を次に置き換える。`sent` に記録する値を
`m.prewarm ? 'prewarm' : m.mode` にするのが要点で、既存の期待値（モード名と `null` の配列）は
そのまま通る。`readyState` の既定を `'loading'` にしておくことで、既存のテストは
`DOMContentLoaded` を発火しない限り prewarm の影響を受けない。

```js
function loadContent({ reply = 'ack', sendImpl, attr = 'hiragana', readyState = 'loading' } = {}) {
  const sent = [];
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
      sendMessage(m) { sent.push(m.prewarm ? 'prewarm' : m.mode); return (sendImpl || REPLY[reply])(m); },
    },
  };
  const ctx = { document, window, chrome, setTimeout, clearTimeout, console };
  vm.createContext(ctx);
  vm.runInContext(fs.readFileSync(CONTENT, 'utf8'), ctx);
  return { document, window, sent };
}
```

- [ ] **Step 2: 失敗するテストを書く**

`---- content.js: 送信が失敗したときの回復 ----` セクションの**前**に、新しいセクションとして追加する:

```js
  // ---- content.js: 事前起動 (prewarm) --------------------------------------
  //
  // ホストの PowerShell 起動は実測 1.2 秒かかる。フォーカスしてから払うと
  // 体感の遅れになるので、対象欄を持つ文書を開いた時点で温めておく。

  {
    const t = loadContent();
    t.document.fire('DOMContentLoaded', {});
    check('属性のある文書は prewarm を送る', t.sent, ['prewarm']);
    t.document.fire('DOMContentLoaded', {});
    check('prewarm は文書あたり 1 通だけ', t.sent, ['prewarm']);
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
  // 二重に送られる。prewarm の失敗は捨てるだけであることの裏取り。
  {
    let n = 0;
    const t = loadContent({ sendImpl: () => (++n === 1 ? REPLY.dead() : REPLY.ack()) });
    t.document.fire('DOMContentLoaded', {});
    await sleep(10);
    t.document.fire('focusin', { target: el('hiragana') });
    await sleep(10);
    t.document.fire('focusin', { target: el('hiragana') });
    check('prewarm が失敗しても適用は 1 回だけ', t.sent, ['prewarm', 'hiragana']);
  }
```

- [ ] **Step 3: 落ちることを確認する**

Run: `node test\content.test.js`
Expected: FAIL。`属性のある文書は prewarm を送る` が `期待: ["prewarm"] / 実際: []`、
`読み込み済みの文書では即座に prewarm` も同様に落ちる。
`属性が無い文書は prewarm を送らない` は実装前でも通る（何も送っていないため）。

- [ ] **Step 4: 実装する**

`extension/content.js` の `const UNKNOWN = Symbol('unknown');` の**次の行**に空行を挟んで追加:

```js
// ホストの PowerShell 起動は実測 1.2 秒かかる（内訳: powershell の起動 650ms と
// Add-Type による C# の実行時コンパイル 350ms）。フォーカスしてから払うと体感の
// 遅れになるので、対象欄を持つ文書を開いた時点で温めておく。ポートを持つのは
// サービスワーカーなので、1 度温めれば全タブで共有される。
let prewarmSent = false;

function prewarm() {
  if (prewarmSent) return;
  // 属性の存在だけを見る。値が既知のモードかは modeOf() の仕事で、判定を
  // 2 か所に持つと食い違って壊れる。属性を使っていないページでは 1 通も
  // 送らないので、PowerShell は起動しない。
  if (!document.querySelector(`[${ATTR}]`)) return;
  prewarmSent = true;
  try {
    // 適用ではないので currentMode には触らず、失敗も捨てる。forget() を
    // 呼ぶと重複排除の状態が汚れる。温め損なっても、次の適用が起動コストを
    // 払うだけで動作は正しい。
    const sent = chrome.runtime.sendMessage({ type: 'ime', prewarm: true });
    if (sent && typeof sent.catch === 'function') sent.catch(() => {});
  } catch {
    // 拡張機能の再読み込み中。次の適用でまた起動が試みられる。
  }
}
```

`extension/content.js` の末尾（`document.addEventListener('visibilitychange', ...)` の後）に追加:

```js

// content script は document_start で走るので、この時点では DOM がまだ無い。
// 他の実行タイミングで読み込まれても壊れないよう、両方に備える。
if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', prewarm, { once: true });
} else {
  prewarm();
}
```

- [ ] **Step 5: 通ることを確認する**

Run: `node test\content.test.js`
Expected: PASS（26/26。Task 1 までの 20 件 + このタスクの 6 件）

- [ ] **Step 6: commit**

```bash
git add extension/content.js test/content.test.js
git commit -m "content: 対象欄を持つ文書を開いた時点でホストを温める"
```

---

### Task 3: ping が IME に触らないことを実機で確かめる

**Files:**
- Modify: `test/host.e2e.ps1`（`--- ポート断の保険 ---` セクションの後、`try` ブロックの末尾）
- Test: `test/host.e2e.ps1` 自体

**Interfaces:**
- Consumes: 既存の `Start-ImeHost`、`Invoke-Host`、`Get-State`、`Set-State`、`Check`、`Hex`
- Produces: なし

**なぜこのテストが必要か**: prewarm は `ping` を送る。もし `ping` が `$script:lastChange` を
設定してしまうと、ポートが切れたときに「元へ戻す」処理が走り、**ユーザーが自分で選んだ
IME 状態を prewarm が勝手に書き換える**ことになる。ホストは `ping` を早期 return して
いるので現状は安全だが、その安全性は暗黙なので固定する。

- [ ] **Step 1: 失敗しないことを先に確認する（現状の記録）**

Run: `powershell -ExecutionPolicy Bypass -File test\host.e2e.ps1`
Expected: PASS（22/22）。ここを基準にする。

- [ ] **Step 2: テストを追加する**

`$proc = Start-ImeHost $hostCopy` の**直前**に、後片付け用の変数を宣言する:

```powershell
$pingProc = $null
```

`try` ブロックの中、`Check 'ポート断: conv が元に戻る' (Hex $now.conv) (Hex $BASE)` の**後**に追加:

```powershell
    # --- ping は IME に触らない -----------------------------------------------
    # prewarm は ping を送るだけ。ここで lastChange が設定されると、ポートが
    # 切れたときに「元へ戻す」処理が走り、ユーザー自身が選んだ状態を
    # prewarm が書き換えてしまう。別プロセスを起こして確かめる。
    Set-State $ime 1 0x001B
    $baseline = Get-State $ime
    $pingProc = Start-ImeHost $hostCopy
    $r = Invoke-Host $pingProc @{ cmd = 'ping'; id = 200 }
    Check 'ping: 応答する' "$($r.ok)" 'True'
    $pingProc.StandardInput.Close()
    if (-not $pingProc.WaitForExit(8000)) { throw 'ping だけのホストが終了しない' }
    Start-Sleep -Milliseconds $SETTLE_MS
    $now = Get-State $ime
    Check 'ping のみ: ポート断でも open が変わらない' $now.open $baseline.open
    Check 'ping のみ: ポート断でも conv が変わらない' (Hex $now.conv) (Hex $baseline.conv)
```

`finally` ブロックの先頭（`if (-not $proc.HasExited) {` の**前**）に後片付けを追加:

```powershell
    if ($null -ne $pingProc -and -not $pingProc.HasExited) {
        try { $pingProc.StandardInput.Close() } catch { }
        $pingProc.WaitForExit(3000) | Out-Null
    }
```

- [ ] **Step 3: 通ることを確認する**

Run: `powershell -ExecutionPolicy Bypass -File test\host.e2e.ps1`
Expected: PASS（25/25）。`ping のみ:` の 2 項目が増えている。

- [ ] **Step 4: テストが空振りでないことを確かめる**

`host/ime-host.ps1` の `if ($cmd -eq 'ping') { return @{ ok = $true } }` を一時的に
コメントアウトして（`ping` が `set` と同じ経路へ落ちるようにして）実行し、
`ping のみ:` が落ちることを確認する。確認後、**必ず元に戻す**。

Run: `powershell -ExecutionPolicy Bypass -File test\host.e2e.ps1`
Expected: `ping: 応答する` が FAIL する（期待 `True` / 実際 `False`）。早期 return を
外すと `ping` は `$cmd -ne 'set'` の判定まで落ち、`unknown cmd: ping` を返すため。
落ちることが確認できれば、このテストは早期 return の有無を見ている。

```bash
git checkout host/ime-host.ps1
```

- [ ] **Step 5: commit**

```bash
git add test/host.e2e.ps1
git commit -m "test: ping が IME に触らないことを実機で確かめる"
```

---

### Task 4: README を更新して全スイートを回す

**Files:**
- Modify: `README.md`（`## しくみ` の中に節を追加、`## 制限` の該当行を修正）

**Interfaces:** なし

- [ ] **Step 1: 起動タイミングの記述を直す**

`## 制限` の中の次の項目を探す:

```markdown
- ホストプロセスは Edge の起動時ではなく、**初めて制御対象の欄にフォーカス
  した時**に起動します（`connect()` が遅延実行のため）。その瞬間にコンソール
  ウィンドウが一瞬見えることがありますが、以降はポートが繋がったままなので
  セッション中 1 回だけです。属性を使っていないページしか見ない間は、
  PowerShell は 1 度も起動しません。
```

次に置き換える:

```markdown
- ホストプロセスは Edge の起動時ではなく、**属性を含むページを開いた時**に
  起動します（[事前起動](#事前起動prewarm)）。その瞬間にコンソールウィンドウが
  一瞬見えることがありますが、以降はポートが繋がったままなのでセッション中
  1 回だけです。属性を使っていないページしか見ない間は、PowerShell は 1 度も
  起動しません。
```

- [ ] **Step 2: しくみに節を追加する**

`### 送信に失敗したとき` の節の**後**、`## インストール` の**前**に追加する:

```markdown
### 事前起動（prewarm）

ホストの PowerShell プロセスは起動に時間がかかります。同一環境で 3 回ずつ測った値:

| 区間 | 時間 |
|---|---|
| ホスト起動 → 最初の応答（コールド） | 1,220 – 1,310 ms |
| 2 回目以降（ポート確立後） | 0.3 – 2.0 ms |
| 内訳: `powershell.exe` の起動だけ | 637 – 762 ms |
| 内訳: `Add-Type`（C# の実行時コンパイル）だけ | 340 – 468 ms |

フォーカスしてからこれを払うと、初回だけ IME の切り替わりが目に見えて遅れます。
そこで content.js は、**属性を持つ要素がある文書を開いた時点で** `ping` を 1 通
送ってホストを起動させておきます。判定は属性の存在だけで、値が既知のモードかは
見ません（値は後から変わりうるうえ、`modeOf()` と判定を二重に持つと食い違います）。

`ping` を選ぶ理由は、ホストがこれを最初に処理して即返し、**ウィンドウ解決も IME
操作もしない**ことです。`lastChange` も設定されないので、prewarm だけしてポートが
切れても復帰処理は走りません。

ポートを持つのはサービスワーカーなので、**1 度温めれば全タブ・全フレームで共有
されます**。ページ遷移ごとに prewarm は走りますが、プロセスが起動するのは最初の
1 回だけで、2 回目以降は `ping` の往復（~1ms）で終わります。サービスワーカーが
破棄されてポートが切れた場合も、次のページ遷移が温め直します。

なお、prewarm は `spec` を持たないメッセージです。background.js は**`spec` の判定より
前に**これを分岐させます。後ろに置くと、`msg.spec ? acquire(msg.spec) : release()` の
`release()` 側に落ちて、ページを開くたびに解放が走ります。

読み込み時点で対象欄が無く、あとから JavaScript で追加される文書だけは prewarm の
対象外です。その場合でも、同じセッションで属性を含むページを 1 度開いていれば
ホストは既に起動しています。
```

- [ ] **Step 3: リンクが解決することを確認する**

Run: `powershell -Command "Select-String -Path README.md -Pattern '事前起動'"`
Expected: `## 制限` 側のリンク `(#事前起動prewarm)` と、見出し `### 事前起動（prewarm）` の
両方が出る。GitHub の日本語見出しのアンカーは全角括弧が落ちるため、`#事前起動prewarm` になる。

- [ ] **Step 4: 全スイートを回す**

```bash
node test\content.test.js
powershell -ExecutionPolicy Bypass -File test\host.test.ps1
powershell -ExecutionPolicy Bypass -File test\host.e2e.ps1
```

Expected: 26/26、8/8、25/25

- [ ] **Step 5: commit**

```bash
git add README.md
git commit -m "docs: 事前起動（prewarm）の節を追加し、起動タイミングの記述を直す"
```

---

## 実機での確認（人手）

自動テストは content.js を DOM のスタブ上で、ホストを WinForms のウィンドウ相手に
確認するだけなので、最後に Edge で次を見る。

- [ ] `edge://extensions` で拡張機能を再読み込みする
- [ ] Edge を再起動し、`test\test.html` を開く。**まだフォーカスしない**
- [ ] タスクマネージャで `powershell.exe` が立っていることを確認する（＝ prewarm が効いている）
- [ ] 項目 1 の欄にフォーカスし、待ちなしで IME 表示が変わることを確認する
- [ ] 属性を使っていないページ（例: `about:blank` 以外の任意のサイト）だけを開いた
      状態では `powershell.exe` が立たないことを確認する
- [ ] 項目 9 で欄を追加し、その欄でも待ちなしで切り替わることを確認する
