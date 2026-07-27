# ブラウザ起動時の事前起動（onStartup prewarm）実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Edge の起動時にネイティブホストを温め、`autofocus` された対象欄でも初回フォーカスの IME 切り替えが間に合うようにする。

**Architecture:** `extension/background.js` に `chrome.runtime.onStartup` のリスナーを 1 行足し、既存の直列キュー経由で `ping` を 1 通送る。`connect()` の単一プロセス化ガードにそのまま乗るのでプロセスは増えない。`content.js` / `manifest.json` / ホスト側は変更しない。

**Tech Stack:** MV3 拡張機能（素の JavaScript、ビルドなし）、PowerShell 5.1 のネイティブホスト、テストは Node の `vm` と PowerShell のみ（依存パッケージなし）。

**設計:** [docs/superpowers/specs/2026-07-27-onstartup-prewarm-design.md](../specs/2026-07-27-onstartup-prewarm-design.md)

## Global Constraints

- 依存パッケージを増やさない。テストは `node test\content.test.js` と `powershell -File test\host.test.ps1` / `test\host.e2e.ps1` のみ。
- ビルド工程を作らない。`extension\` はそのまま「展開して読み込み」できる状態を保つ。
- `extension/content.js`、`extension/manifest.json`、`host/` 配下、`test/host.test.ps1`、`test/host.e2e.ps1` は**変更しない**。
- `manifest.json` の `matches` は `<all_urls>` のまま。
- リスナー登録は `background.js` のトップレベルに置く。非同期の内側で登録するとサービスワーカーがイベントを取りこぼす。
- **Task 2 は設計ゲートである。** ここが不合格なら Task 3 へ進まず、Task 1 を revert して設計判断からやり直す。

---

### Task 1: onStartup リスナーの追加

**Files:**
- Modify: `test/content.test.js:67-102`（`loadBackground()` のスタブと返り値）
- Modify: `test/content.test.js:435` の直後（アサーションの追加）
- Modify: `extension/background.js:116-118` の直後（リスナーの追加）

**Interfaces:**
- Consumes: 既存の `enqueue(fn)`（`background.js:89`）、`call(req)`（`background.js:43`）、`connect()`（`background.js:18`）。いずれもシグネチャ変更なし。
- Produces: `loadBackground()` の返り値に `startupHandler` が増える（`Function | null`。`chrome.runtime.onStartup.addListener` に渡されたハンドラそのもの。引数なしで呼ぶと onStartup の発火を模す）。既存の `listener` / `posted` / `connectStats` は変わらない。

- [ ] **Step 1: `loadBackground()` のスタブに `onStartup` を足す**

`test/content.test.js` の `loadBackground()` を次のように変える。変更は 3 か所（`startupHandler` の宣言、`chrome.runtime.onStartup` の追加、返り値への追加）で、それ以外の行は現状のままにする。

```js
function loadBackground({ respond } = {}) {
  let listener = null;
  let startupHandler = null;
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
      onStartup: { addListener: (fn) => { startupHandler = fn; } },
      lastError: null,
    },
  };
  const ctx = { chrome, setTimeout, clearTimeout, setInterval: () => 0, console, Promise };
  vm.createContext(ctx);
  vm.runInContext(fs.readFileSync(BACKGROUND, 'utf8'), ctx);
  return { listener, startupHandler, posted, connectStats };
}
```

- [ ] **Step 2: 失敗するテストを書く**

`test/content.test.js` の「危険な経路: saved を保持中に prewarm が届く場合」ブロックの閉じ括弧（`test/content.test.js:435` の `}`）の直後、`// ---- 結果 ----` の行より前に、次を挿入する。

```js
  // ---- background.js: onStartup による起動時の温め ------------------------
  //
  // 既存の prewarm は「属性を含む文書を開いた時点」で温めるので、対象欄が
  // autofocus されているページではフォーカスと同じ瞬間になり利得がゼロになる。
  // ブラウザの起動時に温めることで、ページより前に 1.2 秒を払い終える。
  {
    const { startupHandler, posted, connectStats } = loadBackground({
      respond: (m) => (m.cmd === 'ping' ? { id: m.id, ok: true } : undefined),
    });

    // サービスワーカーは頻繁に起き直る。ここをトップレベルの即時実行に
    // 書き換えると、起きるたびに PowerShell が 1 プロセス生まれる。
    // このアサーションだけがそれを止めている。
    check('background が onStartup にハンドラを登録する', typeof startupHandler, 'function');
    check('onStartup の登録だけでは connectNative を呼ばない', connectStats.count, 0);

    startupHandler();
    await sleep(10);
    check('onStartup の発火で connectNative を 1 回だけ呼ぶ', connectStats.count, 1);
    // ping だけであること = ウィンドウ解決も IME 操作もしないこと。
    // set が混じると、誰も要求していないのに IME を書き換えることになる。
    check('onStartup が送るのは ping だけ', posted.map((m) => m.cmd), ['ping']);
  }

  // ---- background.js: onStartup の後もプロセスは増えない --------------------
  //
  // 起動時に温めたあと、対象ページを開くとページ単位 prewarm も飛ぶ。
  // connect() のガード (background.js:19) が onStartup 経由でも効いていないと、
  // ここで 2 プロセス目が立つ。
  {
    const { listener, startupHandler, connectStats } = loadBackground({
      respond: (m) => (m.cmd === 'ping' ? { id: m.id, ok: true } : undefined),
    });

    startupHandler();
    await sleep(10);
    listener({ type: 'ime', prewarm: true }, {}, () => {});
    await sleep(10);
    check('onStartup の後のページ prewarm は connectNative を増やさない', connectStats.count, 1);
  }
```

- [ ] **Step 3: テストを走らせて失敗を確かめる**

Run: `node test\content.test.js`

Expected: FAIL。`background が onStartup にハンドラを登録する` が `期待: "function"` / `実際: "object"`（`startupHandler` が `null` のまま）になる。続く `onStartup の発火で...` の 2 件は `startupHandler()` が `TypeError` を投げるため、テスト全体がそこで止まる可能性がある。止まった場合も「実装がまだ無い」ことの確認としては十分なので、そのまま Step 4 へ進む。

- [ ] **Step 4: 実装する**

`extension/background.js` の末尾、`setInterval` の keepalive（`background.js:116-118`）の直後に次を足す。

```js

// Edge の起動時点で温める。属性付きページを開いた時では、autofocus された
// 対象欄には間に合わない（フォーカスと prewarm が同じ瞬間に起きる）。
chrome.runtime.onStartup.addListener(() => enqueue(() => call({ cmd: 'ping' })));
```

登録はトップレベルに置く（`onMessage` の登録や `setInterval` と同じ場所）。サービスワーカーはイベントで起き直すため、非同期の内側で登録するとイベントを取りこぼす。

- [ ] **Step 5: テストを走らせて通ることを確かめる**

Run: `node test\content.test.js`

Expected: PASS。末尾の `N/N passed` で N が 5 件増え、`未処理の reject` が 0 件（表示されない）であること。

- [ ] **Step 6: 既存のホスト側テストが影響を受けていないことを確かめる**

Run: `powershell -ExecutionPolicy Bypass -File test\host.test.ps1`

Expected: PASS。ホスト側は変更していないので、変わっていないことの確認である。

- [ ] **Step 7: commit**

```bash
git add extension/background.js test/content.test.js
git commit -m "feat: Edge の起動時にネイティブホストを温める

既存の prewarm は属性を含む文書を開いた時点で温めるため、対象欄が autofocus
されているページではフォーカスと同じ瞬間になり利得がゼロになる。ユーザーは
1.2 秒まちがったモードで打ち、打鍵の途中で IME が切り替わる。

chrome.runtime.onStartup で温めることでページより前に払い終える。既存の直列
キューと connect() の単一プロセス化ガードにそのまま乗るのでプロセスは増えない。

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: 実機で先行が取れているかを測る（設計ゲート）

**このタスクは合否のあるゲートである。** 不合格なら Task 3 へ進まず、Task 1 を revert して設計判断からやり直す。ここで測るのは「起動時の温めが、復元されたタブの描画より先に終わっているか」で、取れていなければこの変更は放棄する不変条件（属性を使っていないページでは PowerShell を起動しない）だけを失って何も得ない。

**Files:**
- Create: `host/debug.on`（空ファイル。測定後に削除する）
- Create: 測定用のコピー（リポジトリ外。スクラッチ領域に置く）

自動テストは無い。人手の測定である。

- [ ] **Step 1: 拡張機能を読み込み直す**

`edge://extensions` で本拡張機能の「再読み込み」を押す。`background.js` を変更したので、これをしないと古いサービスワーカーが動き続ける。

- [ ] **Step 2: 診断ログを有効にする**

```bash
touch host/debug.on
rm -f host/debug.log
```

`host/debug.on` があるとホストが `host/debug.log` に書く（`host/ime-host.ps1:55-57`）。プロセスを起動するのは Edge なので環境変数では切り替えられない。

- [ ] **Step 3: autofocus を持つ測定用ページを用意する**

`test/test.html` をリポジトリ外へコピーし、最初の対象欄に `autofocus` を足す。リポジトリの `test/test.html` は変更しない。

```bash
cp test/test.html "$LOCALAPPDATA/Temp/ime-autofocus.html"
```

コピーした側の 24 行目を、

```html
<input type="text" data-ime-mode="inactive" placeholder="郵便番号・社員番号など">
```

次に変える。

```html
<input type="text" data-ime-mode="inactive" placeholder="郵便番号・社員番号など" autofocus>
```

`inactive` を選ぶのは、IME が**オフになるべき**欄だからである。温めが間に合っていなければ、最初の 1.2 秒は日本語入力のままになり、`_ｱ` の表示で目視できる。`hiragana` の欄だと「まだ切り替わっていない」と「もともとオフだった」の区別がつきにくい。

- [ ] **Step 4: 復元されるタブとして仕込む**

そのファイルを `file://` で Edge に開き、**そのタブを開いたまま Edge を完全に終了する**（タスクトレイの常駐も含む）。Edge の設定で「前回のセッションから続行する」が有効になっていることを確認する。有効でない場合は、そのタブをピン留めしておく。

- [ ] **Step 5: Edge を起動して、何も触らずに観察する**

Edge を起動し、**キーボードにもマウスにも触れずに**、復元されたタブの `autofocus` された欄で IME が指定どおりのモードになっているかを見る。

- [ ] **Step 6: ログのタイムスタンプで裏を取る**

Run: `powershell -Command "Get-Content host\debug.log -TotalCount 20"`

見るのは 2 つの時刻の差である。

- `--- host 起動 ---` の時刻（`host/ime-host.ps1:69`。`Add-Type` が終わったあとに書かれるので、ホストが応答可能になった時刻とみなせる）
- 最初の `req {"cmd":"set"...}` の時刻（`host/ime-host.ps1:175`。`autofocus` によるフォーカスが届いた時刻）

**合格の条件**: 最初の `req set` が `--- host 起動 ---` より**後**にあり、両者の差が 200ms 以上あること。加えて Step 5 で IME が最初から正しいモードになっていること。

**不合格の場合**:

- `--- host 起動 ---` の直後（数十 ms 以内）に `req set` が来ている → 温めが競争に負けている。ページの描画が速すぎて先行を取れていない。設計判断をやり直す。
- `debug.log` がそもそも作られない、または `req set` の時刻に初めてホストが立っている → 起動時の温めが走っていない。設計の「サービスワーカーの寿命」節を疑う。手当てとして `background.js` のリスナーを次に差し替えて Step 1 からやり直す。

  ```js
  chrome.runtime.onStartup.addListener(async () => {
    await enqueue(() => call({ cmd: 'ping' }));
  });
  ```

  これで直るなら、その形を採用して Task 1 の実装とテストを更新し、理由をコメントに残す。直らないなら設計判断をやり直す。

- [ ] **Step 7: 起動ブーストとスリープ復帰も見ておく**

同じ `debug.log` で次の 2 つを確認し、結果を控える。合否には使わない（想定の裏取りである）。

- ウィンドウを全部閉じてから開き直したとき、`--- host 起動 ---` が増えないこと（増えなければポートが生き続けており実害なし）
- スリープから復帰したあと、対象欄にフォーカスして応答が ~1ms で返ること（`debug.log` に新しい `--- host 起動 ---` が無いこと）

- [ ] **Step 8: 診断ログを片付ける**

```bash
rm -f host/debug.on host/debug.log
```

どちらも `.gitignore` 済みなので commit される心配はない。消す理由は別で、`debug.on` を置いたままだとホストが要求のたびにログを書き、しかも `Set-ConversionBits` の後に 250ms の `Start-Sleep` を挟む診断経路（`host/ime-host.ps1:243-253`）を通り続けるためである。測定用の細工を残さない。

- [ ] **Step 9: 測定結果を記録して commit**

Step 6 で読んだ 2 つの時刻とその差、Step 7 の結果を、設計文書の「実測で確かめること」節に追記する。ファイルは `docs/superpowers/specs/2026-07-27-onstartup-prewarm-design.md`。各項目の下に「実測（YYYY-MM-DD）: ...」の形で 1〜2 行足す。

```bash
git add docs/superpowers/specs/2026-07-27-onstartup-prewarm-design.md
git commit -m "docs: onStartup prewarm の実測結果を設計文書に記録

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: README の更新

**Task 2 が合格してから着手する。**

**Files:**
- Modify: `README.md:213` の直後（事前起動の節への追記）
- Modify: `README.md:254-258`（既知の制約の書き換え）

- [ ] **Step 1: 事前起動の節に「ブラウザ起動時の温め」を足す**

`README.md:213`（「ホストは既に起動しています。」の行）の直後、`## インストール`（`README.md:215`）より前に、空行を挟んで次を挿入する。

```markdown
#### ブラウザ起動時の温め

上の prewarm には塞げない穴があります。対象欄が `autofocus` されているページでは、
**属性が見えるようになる瞬間とフォーカスが起きる瞬間が同じ**なので、prewarm の
利得がゼロになります。ログインフォームはこの拡張機能の本命の用途で、しかも
`autofocus` を持つことが多いところです。

そのとき起きるのは単なる遅れではありません。1.2 秒のあいだまちがったモードで
打つことになり、**打鍵の途中で IME が切り替わります**。`data-ime-mode="inactive"`
を指定した ID 欄なら、その 1.2 秒は日本語入力のままです。

そこで `background.js` は `chrome.runtime.onStartup`、つまり **Edge の起動時**にも
`ping` を 1 通送ります。ページより前なので、どのサイトのどんなフォームでも
初回フォーカスが間に合います。

代償として、対象の欄を 1 度も触らない日でも、Edge を開いている間ずっとホストが
常駐します。実測でコミット 58.1 MB（起動直後の WorkingSet は 83.8 MB ですが、
アイドルのプロセスは Windows に切り詰められます）。CPU は 20 秒ごとの keepalive
込みでほぼゼロです。
```

- [ ] **Step 2: 既知の制約を書き換える**

`README.md:254-258` の次の項目を、

```markdown
- ホストプロセスは Edge の起動時ではなく、**属性を含むページを開いた時**に
  起動します（[事前起動](#事前起動prewarm)）。その瞬間にコンソールウィンドウが
  一瞬見えることがありますが、以降はポートが繋がったままなのでセッション中
  1 回だけです。属性を使っていないページしか見ない間は、PowerShell は 1 度も
  起動しません。
```

次に置き換える。

```markdown
- ホストプロセスは **Edge の起動時**に立ち、以降はポートが繋がったままなので
  セッション中 1 回だけです（[事前起動](#事前起動prewarm)）。**この拡張機能を
  入れている間は、対象の欄を使わない日でもホストが常駐します。**
```

「属性を使っていないページしか見ない間は、PowerShell は 1 度も起動しません」は成立しなくなるため落とす。これは黙って変えてよい性質ではないので、上の太字で明示する。

コンソールウィンドウの記述も落とす。実機では出ていないとの報告があるため。Step 3 で確かめる。

- [ ] **Step 3: コンソールウィンドウが本当に出ないことを確かめる**

Edge を完全に終了してから起動し、起動直後の数秒間、コンソールウィンドウが一瞬でも見えないことを目視する。Task 2 の Step 5 と同じ操作なので、そのとき見ていたなら結果を流用してよい。

**出た場合**: Step 2 で落とした記述を戻す。文面は元のまま、ただし「属性を含むページを開いた時」ではなく「Edge の起動時」に合わせる。

```markdown
- ホストプロセスは **Edge の起動時**に立ちます（[事前起動](#事前起動prewarm)）。
  その瞬間にコンソールウィンドウが一瞬見えることがありますが、以降はポートが
  繋がったままなのでセッション中 1 回だけです。**この拡張機能を入れている間は、
  対象の欄を使わない日でもホストが常駐します。**
```

- [ ] **Step 4: リンクが壊れていないことを確かめる**

Run: `powershell -Command "Select-String -Path README.md -Pattern '事前起動'"`

Expected: 見出し `### 事前起動（prewarm）`、新しい見出し `#### ブラウザ起動時の温め` を含む節、および `[事前起動](#事前起動prewarm)` のアンカーが出ること。アンカー先の見出しは変えていないのでリンクは有効である。

- [ ] **Step 5: テストを一通り走らせる**

```bash
node test\content.test.js
powershell -ExecutionPolicy Bypass -File test\host.test.ps1
```

Expected: どちらも全件 PASS。README だけの変更なので変わっていないことの確認である。

- [ ] **Step 6: commit**

```bash
git add README.md
git commit -m "docs: 起動時の温めと、放棄した不変条件を README に反映

「属性を使っていないページでは PowerShell を 1 度も起動しない」は onStartup
prewarm の導入で成立しなくなる。黙って変えてよい性質ではないので、常駐する
ことを既知の制約に明示した。

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```
