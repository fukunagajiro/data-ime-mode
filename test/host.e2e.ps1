# ime-host.ps1 を実機で end-to-end 確認する。
#
#   powershell -ExecutionPolicy Bypass -File test\host.e2e.ps1
#   powershell -ExecutionPolicy Bypass -File test\host.e2e.ps1 -Log   # ホストの診断ログも残す
#
# ホストを Native Messaging プロトコルで起動し、background.js が送るのと同じ
# JSON を流す。合否はホストの返答ではなく、このスクリプト自身の Win32 読み取りで
# 判定する（検証対象で検証対象を測らないため）。
#
# host.test.ps1 が計算だけを見るのに対し、こちらは WM_IME_CONTROL の往復まで通す。
# 対象は使い捨ての専用ウィンドウなので、Edge と今の IME 状態には触らない。ただし
# 相手は WinForms のテキストボックスであって Edge ではない。ブラウザ側
# （focusin / blur / 再適用）は test\test.html で別途手で確認すること。
#
# この検証台が空振りでないことは、修正前のホスト
# (git show HEAD:host/ime-host.ps1) に同じ検証をかけると「復帰: ROMAN を含む
# 0x0019 が書き戻る」だけが 0x0009 で落ちることで確認している。

param([string]$Source, [switch]$Log)

$ErrorActionPreference = 'Stop'

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class ImeE2E {
  [DllImport("imm32.dll")] public static extern IntPtr ImmGetDefaultIMEWnd(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern IntPtr SendMessageTimeout(
      IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam,
      uint fuFlags, uint uTimeout, out IntPtr lpdwResult);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
}
"@

$WM_IME_CONTROL = 0x0283
$GETCONV = 0x0001
$SETCONV = 0x0002
$GETOPEN = 0x0005
$SETOPEN = 0x0006

# 書き込み後に読み直すまでの待ち。TSF は非同期に反映することがあるので、
# 待たずに読むと「拒否された」と誤読する。test-ime-conversion.ps1 が 1.2 秒
# 待つのと同じ理由。
$SETTLE_MS = 800

# 実ログで観測された前提状態: NATIVE|FULLSHAPE|ROMAN。ROMAN が非マスクビットで、
# 復帰の壊れ方がここに出るため、あえてこの値を基準にする。
$BASE = 0x0019

# --- 検証対象とは独立した Win32 アクセス --------------------------------------

function Send-Ime([IntPtr]$ime, [int]$cmd, [int]$value) {
    $r = [IntPtr]::Zero
    $ok = [ImeE2E]::SendMessageTimeout($ime, $WM_IME_CONTROL, [IntPtr]$cmd, [IntPtr]$value, 0x0002, 1000, [ref]$r)
    if ($ok -eq [IntPtr]::Zero) { return $null }
    return [int]$r
}

function Get-State([IntPtr]$ime) {
    @{ open = (Send-Ime $ime $GETOPEN 0); conv = (Send-Ime $ime $GETCONV 0) }
}

# 前提状態づくり。変換モードは IME が開いていないと反映されないので、
# 開けてから書き、最後に目的の開閉状態にする。
function Set-State([IntPtr]$ime, [int]$open, [int]$conv) {
    Send-Ime $ime $SETOPEN 1 | Out-Null
    Send-Ime $ime $SETCONV $conv | Out-Null
    Start-Sleep -Milliseconds 300
    Send-Ime $ime $SETOPEN $open | Out-Null
    Start-Sleep -Milliseconds 300
}

# --- Native Messaging クライアント --------------------------------------------

function Start-ImeHost([string]$path) {
    # .NET の StandardInput は Console.InputEncoding のプリアンブルを吐く。UTF-8 だと
    # BOM (EF BB BF) が先頭に混ざり、長さプレフィックスが 4 バイトずれて壊れる。
    # Edge は生バイトを書くので製品経路には無い、この検証台だけの落とし穴。
    [Console]::InputEncoding = New-Object Text.UTF8Encoding $false

    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = (Get-Command powershell).Source
    # Edge が ime-host.bat 経由で使うのと同じ引数に揃える。
    $psi.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$path`""
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    return [Diagnostics.Process]::Start($psi)
}

function Send-Req($proc, [hashtable]$req) {
    $bytes = [Text.Encoding]::UTF8.GetBytes(($req | ConvertTo-Json -Compress))
    $s = $proc.StandardInput.BaseStream
    $s.Write([BitConverter]::GetBytes([int]$bytes.Length), 0, 4)
    $s.Write($bytes, 0, $bytes.Length)
    $s.Flush()
}

function Receive-Resp($proc, [int]$timeoutMs = 8000) {
    $s = $proc.StandardOutput.BaseStream
    $lenBuf = New-Object byte[] 4
    $t = $s.ReadAsync($lenBuf, 0, 4)
    if (-not $t.Wait($timeoutMs)) { throw 'ホストからの応答がタイムアウト' }
    if ($t.Result -ne 4) { throw "長さプレフィックスが読めない ($($t.Result) バイト。ホストが落ちた可能性)" }
    $len = [BitConverter]::ToInt32($lenBuf, 0)
    $body = New-Object byte[] $len
    $off = 0
    while ($off -lt $len) {
        $t2 = $s.ReadAsync($body, $off, $len - $off)
        if (-not $t2.Wait($timeoutMs)) { throw '本文の読み取りがタイムアウト' }
        $off += $t2.Result
    }
    return ([Text.Encoding]::UTF8.GetString($body) | ConvertFrom-Json)
}

function Invoke-Host($proc, [hashtable]$req) {
    Send-Req $proc $req
    return Receive-Resp $proc
}

# --- 判定 ---------------------------------------------------------------------

$script:results = @()
function Check([string]$name, $actual, $expected) {
    $script:results += [pscustomobject]@{
        Name = $name; Ok = ("$actual" -eq "$expected"); Expected = $expected; Actual = $actual
    }
}
function Hex($v) { if ($null -eq $v) { '(読めず)' } else { '0x{0:X4}' -f [int]$v } }

# --- 準備 ---------------------------------------------------------------------

# ホストは PSScriptRoot を見て debug.on / debug.log を扱う。実物をそのまま起動すると
# host\debug.log に混ざるので、作業用ディレクトリへコピーして走らせる（内容は同一）。
$src = if ($Source) { $Source } else { Join-Path $PSScriptRoot '..\host\ime-host.ps1' }
$src = (Resolve-Path $src).Path
$work = Join-Path ([IO.Path]::GetTempPath()) ('ime-e2e-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $work | Out-Null
$hostCopy = Join-Path $work 'ime-host.ps1'
Copy-Item $src $hostCopy
if ($Log) { New-Item -ItemType File -Path (Join-Path $work 'debug.on') | Out-Null }

Write-Host "== 対象ウィンドウを用意 =="
$handleFile = Join-Path $work 'target.hwnd'
$win = Start-Process powershell -PassThru -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
    (Join-Path $PSScriptRoot 'host.e2e.window.ps1'), $handleFile)
for ($i = 0; $i -lt 100 -and -not (Test-Path $handleFile); $i++) { Start-Sleep -Milliseconds 100 }
if (-not (Test-Path $handleFile)) { $win.Kill(); throw '対象ウィンドウが起動しない' }

$hwnd = [IntPtr][int64](Get-Content $handleFile -Raw).Trim()
[ImeE2E]::SetForegroundWindow($hwnd) | Out-Null
Start-Sleep -Milliseconds 500

$ime = [ImeE2E]::ImmGetDefaultIMEWnd($hwnd)
Write-Host ("  hwnd=0x{0:X} ime=0x{1:X}" -f [int64]$hwnd, [int64]$ime)
if ($ime -eq [IntPtr]::Zero) {
    $win.Kill()
    throw 'IME ウィンドウが取れない（日本語 IME が有効か確認）'
}

$orig = Get-State $ime
Write-Host ("  対象ウィンドウの元の状態: open={0} conv={1}" -f $orig.open, (Hex $orig.conv))

$pingProc = $null

$proc = Start-ImeHost $hostCopy

try {
    # --- 疎通 -----------------------------------------------------------------
    $r = Invoke-Host $proc @{ cmd = 'ping'; id = 100 }
    Check 'ping に応答し id を echo する' "$($r.ok)/$($r.id)" 'True/100'

    # --- get が実状態を返す ---------------------------------------------------
    Set-State $ime 0 $BASE
    $before = Get-State $ime
    $r = Invoke-Host $proc @{ cmd = 'get'; hwnd = [int64]$hwnd; id = 101 }
    Check 'get: open が実状態と一致' $r.open $before.open
    Check 'get: conv が実状態と一致' (Hex $r.conv) (Hex $before.conv)

    # --- 適用: 半角カナ（マスク経路。ROMAN を保ち FULLSHAPE を落とす）--------
    Set-State $ime 0 $BASE
    $pre = Get-State $ime
    $r = Invoke-Host $proc @{ cmd = 'set'; open = 1; conv = 'half-katakana'; hwnd = [int64]$hwnd; id = 1 }
    Start-Sleep -Milliseconds $SETTLE_MS
    $now = Get-State $ime
    Check '適用(半角カナ): IME が開く' $now.open 1
    Check '適用(半角カナ): conv=0x0013 (ROMAN 保持)' (Hex $now.conv) (Hex 0x0013)
    Check '適用(半角カナ): previousConv を正しく返す' (Hex $r.previousConv) (Hex $pre.conv)
    Check '適用(半角カナ): previous(open) を正しく返す' $r.previous $pre.open

    # --- 復帰: 捕獲値をそのまま書き戻す ---------------------------------------
    Invoke-Host $proc @{
        cmd = 'set'; open = $r.previous; convRaw = [int]$r.previousConv
        hwnd = [int64]$hwnd; restore = $true; id = 2
    } | Out-Null
    Start-Sleep -Milliseconds $SETTLE_MS
    $now = Get-State $ime
    Check '復帰: IME が元どおり閉じる' $now.open $pre.open
    Check '復帰: conv が捕獲値ちょうどに戻る' (Hex $now.conv) (Hex $pre.conv)

    # --- 適用: 全角カナ -------------------------------------------------------
    Set-State $ime 0 $BASE
    Invoke-Host $proc @{ cmd = 'set'; open = 1; conv = 'full-katakana'; hwnd = [int64]$hwnd; id = 3 } | Out-Null
    Start-Sleep -Milliseconds $SETTLE_MS
    $now = Get-State $ime
    Check '適用(全角カナ): conv=0x001B' (Hex $now.conv) (Hex 0x001B)
    Invoke-Host $proc @{ cmd = 'set'; open = 0; convRaw = $BASE; hwnd = [int64]$hwnd; restore = $true; id = 4 } | Out-Null

    # --- 回帰: 非マスクビットだけが食い違う復帰 -------------------------------
    # 適用中に ROMAN が落ちた状態から捕獲値 0x0019 へ戻す。マスク経由だと
    # target=0x0009 となり現在値と同値でスキップされ、ROMAN が戻らない。
    # ローマ字入力が勝手にかな入力へ化ける、という形で表に出た壊れ方。
    Set-State $ime 1 0x0009
    Start-Sleep -Milliseconds 300
    $mid = Get-State $ime
    Check '回帰: 前提として conv=0x0009 を作れている' (Hex $mid.conv) (Hex 0x0009)
    Invoke-Host $proc @{ cmd = 'set'; open = 0; convRaw = $BASE; hwnd = [int64]$hwnd; restore = $true; id = 5 } | Out-Null
    Start-Sleep -Milliseconds $SETTLE_MS
    $now = Get-State $ime
    Check '回帰: ROMAN を含む 0x0019 が書き戻る' (Hex $now.conv) (Hex $BASE)

    # --- inactive / active（conv 指定なし）------------------------------------
    Set-State $ime 1 $BASE
    Invoke-Host $proc @{ cmd = 'set'; open = 0; hwnd = [int64]$hwnd; id = 6 } | Out-Null
    Start-Sleep -Milliseconds $SETTLE_MS
    $now = Get-State $ime
    Check 'inactive: IME が閉じる' $now.open 0
    Check 'inactive: conv は触らない' (Hex $now.conv) (Hex $BASE)

    Invoke-Host $proc @{ cmd = 'set'; open = 1; hwnd = [int64]$hwnd; id = 7 } | Out-Null
    Start-Sleep -Milliseconds $SETTLE_MS
    $now = Get-State $ime
    Check 'active: IME が開く' $now.open 1
    Check 'active: conv は触らない' (Hex $now.conv) (Hex $BASE)
    Invoke-Host $proc @{ cmd = 'set'; open = 0; convRaw = $BASE; hwnd = [int64]$hwnd; restore = $true; id = 8 } | Out-Null

    # --- 異常系 ---------------------------------------------------------------
    $r = Invoke-Host $proc @{ cmd = 'set'; open = 1; conv = 'nonsense'; hwnd = [int64]$hwnd; id = 9 }
    Check '未知の conv 名を拒否する' "$($r.ok)" 'False'
    $r = Invoke-Host $proc @{ cmd = 'bogus'; hwnd = [int64]$hwnd; id = 10 }
    Check '未知の cmd を拒否する' "$($r.ok)" 'False'
    $r = Invoke-Host $proc @{ cmd = 'ping'; id = 11 }
    Check '拒否のあとも応答を続ける' "$($r.ok)/$($r.id)" 'True/11'

    # --- ポート断の保険 -------------------------------------------------------
    # 復帰要求を送らないまま stdin を閉じる。finally 節が元へ戻すこと。
    # サービスワーカーが破棄された場合に相当する。
    Set-State $ime 0 $BASE
    Invoke-Host $proc @{ cmd = 'set'; open = 1; conv = 'half-katakana'; hwnd = [int64]$hwnd; id = 12 } | Out-Null
    Start-Sleep -Milliseconds $SETTLE_MS
    $held = Get-State $ime
    Check 'ポート断: 前提として適用済み (0x0013)' (Hex $held.conv) (Hex 0x0013)

    $proc.StandardInput.Close()
    if (-not $proc.WaitForExit(8000)) { throw 'ホストが終了しない' }
    Start-Sleep -Milliseconds $SETTLE_MS
    $now = Get-State $ime
    Check 'ポート断: open が元に戻る' $now.open 0
    Check 'ポート断: conv が元に戻る' (Hex $now.conv) (Hex $BASE)

    # --- ping は IME に触らない -----------------------------------------------
    # prewarm は ping を送るだけ。危険なのは ping の直後からポートが切れるまでの
    # 間に、ユーザー自身が IME を切り替えるケース。ここで ping が lastChange を
    # 記録してしまうと、ポート断時の「元へ戻す」処理がユーザーの変更を
    # prewarm 実行前の状態へ勝手に巻き戻してしまう。単に無変化を保つだけでは
    # この壊れ方を検出できない（巻き戻し先と現在値が同値だと書き込みが
    # スキップされ、区別がつかない）ので、ping の後でユーザー操作を模して
    # 状態を変えてから確かめる。
    Set-State $ime 1 0x001B
    $baseline = Get-State $ime
    # baseline が afterPing と別の値であることに、この後の判定は依存している
    # (下のコメント参照)。ここで意図どおりの値を作れているか確かめておかないと、
    # baseline が想定と違っていても afterPing と偶然食い違うだけで
    # テストが非自明なまま通ってしまう。
    Check 'ping: 前提として baseline を作れている' "$($baseline.open)/$(Hex $baseline.conv)" "1/$(Hex 0x001B)"
    $pingProc = Start-ImeHost $hostCopy
    $r = Invoke-Host $pingProc @{ cmd = 'ping'; id = 200 }
    Check 'ping: 応答する' "$($r.ok)" 'True'

    # ping の直後、ユーザー自身が IME を切り替えたことを模す。baseline とは
    # open・conv とも異なる値にして、巻き戻り先の baseline と区別できるようにする。
    Set-State $ime 0 0x0009
    $afterPing = Get-State $ime
    Check 'ping のみ: 前提として baseline と異なる状態を作れている' "$($afterPing.open)/$(Hex $afterPing.conv)" "0/$(Hex 0x0009)"

    $pingProc.StandardInput.Close()
    if (-not $pingProc.WaitForExit(8000)) { throw 'ping だけのホストが終了しない' }
    Start-Sleep -Milliseconds $SETTLE_MS
    $now = Get-State $ime
    Check 'ping のみ: ポート断でユーザーの変更が巻き戻らない (open)' $now.open $afterPing.open
    Check 'ping のみ: ポート断でユーザーの変更が巻き戻らない (conv)' (Hex $now.conv) (Hex $afterPing.conv)
}
finally {
    if ($null -ne $pingProc -and -not $pingProc.HasExited) {
        try { $pingProc.StandardInput.Close() } catch { }
        $pingProc.WaitForExit(3000) | Out-Null
    }
    if (-not $proc.HasExited) {
        try { $proc.StandardInput.Close() } catch { }
        $proc.WaitForExit(3000) | Out-Null
    }
    $err = $proc.StandardError.ReadToEnd()
    if ($err.Trim()) { Write-Host "`n== ホストの stderr ==`n$err" -ForegroundColor DarkYellow }

    # ウィンドウごと捨てるので IME 状態も道連れだが、念のため戻してから閉じる。
    Set-State $ime $orig.open $orig.conv
    $win.Kill()

    # -Log のときは作業用ディレクトリを残す。リポジトリを汚さないよう、
    # ホストの診断ログはここに置いたままにする。
    if ($Log) {
        Write-Host "ホストの診断ログ: $(Join-Path $work 'debug.log')"
    } else {
        Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ''
$bad = 0
foreach ($r in $script:results) {
    if ($r.Ok) {
        Write-Host ('PASS  ' + $r.Name)
    } else {
        $bad++
        Write-Host ('FAIL  ' + $r.Name) -ForegroundColor Red
        Write-Host ('        期待: ' + $r.Expected)
        Write-Host ('        実際: ' + $r.Actual)
    }
}
Write-Host ''
Write-Host ("{0}/{1} passed" -f ($script:results.Count - $bad), $script:results.Count)
if ($bad) { exit 1 }
