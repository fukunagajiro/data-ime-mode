#requires -Version 5.1
# Native Messaging host for the data-ime-mode extension.
# Speaks Chromium's stdio protocol (4-byte native-order length prefix + UTF-8 JSON)
# and drives the IME open state / conversion mode of a target window via WM_IME_CONTROL.

$ErrorActionPreference = 'Stop'

Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public class ImeNative {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("imm32.dll")]  public static extern IntPtr ImmGetDefaultIMEWnd(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern IntPtr SendMessageTimeout(
        IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam,
        uint fuFlags, uint uTimeout, out IntPtr lpdwResult);

    // 診断用: 書き込み先が本当に Edge なのかを記録するため。
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(
        IntPtr hWnd, out uint lpdwProcessId);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(
        IntPtr hWnd, StringBuilder lpString, int nMaxCount);
}
"@

$WM_IME_CONTROL        = 0x0283
$IMC_GETCONVERSIONMODE = 0x0001
$IMC_SETCONVERSIONMODE = 0x0002
$IMC_GETOPENSTATUS     = 0x0005
$IMC_SETOPENSTATUS     = 0x0006
$SMTO_ABORTIFHUNG      = 0x0002
$SEND_TIMEOUT_MS       = 200

$IME_CMODE_NATIVE    = 0x0001
$IME_CMODE_KATAKANA  = 0x0002
$IME_CMODE_FULLSHAPE = 0x0008

# Only these three bits are ours. ROMAN (ローマ字入力/かな入力) and everything
# else belongs to the user's own IME configuration and must survive untouched.
$CONV_MASK = $IME_CMODE_NATIVE -bor $IME_CMODE_KATAKANA -bor $IME_CMODE_FULLSHAPE

$CONV_BITS = @{
    'hiragana'      = $IME_CMODE_NATIVE -bor $IME_CMODE_FULLSHAPE                          # 0x09
    'full-katakana' = $IME_CMODE_NATIVE -bor $IME_CMODE_KATAKANA -bor $IME_CMODE_FULLSHAPE  # 0x0B
    'half-katakana' = $IME_CMODE_NATIVE -bor $IME_CMODE_KATAKANA                            # 0x03
}

$stdin  = [Console]::OpenStandardInput()
$stdout = [Console]::OpenStandardOutput()

# 診断ログ。host\debug.on を置くと有効になる。プロセスを起動するのは Edge なので
# 環境変数では切り替えられない。stdout はプロトコル専用なので必ずファイルへ書く。
$script:logPath = $null
if (Test-Path (Join-Path $PSScriptRoot 'debug.on')) {
    $script:logPath = Join-Path $PSScriptRoot 'debug.log'
}

function Write-DebugLog([string]$msg) {
    if ($null -eq $script:logPath) { return }
    try {
        [IO.File]::AppendAllText(
            $script:logPath,
            ('{0:HH:mm:ss.fff}  {1}{2}' -f (Get-Date), $msg, [Environment]::NewLine),
            [Text.Encoding]::UTF8)
    } catch { }
}

Write-DebugLog '--- host 起動 ---'

# 診断専用。ウィンドウがどのアプリのものかを人間が読める形にする。
# 「Edge に書いたつもりが別アプリだった」を一目で分かるようにするため。
function Get-WindowLabel([IntPtr]$hWnd) {
    if ($hWnd -eq [IntPtr]::Zero) { return '(なし)' }
    try {
        $pid32 = 0
        [void][ImeNative]::GetWindowThreadProcessId($hWnd, [ref]$pid32)
        $name = try { (Get-Process -Id $pid32 -ErrorAction Stop).ProcessName } catch { "pid $pid32" }
        $sb = New-Object Text.StringBuilder 256
        [void][ImeNative]::GetWindowTextW($hWnd, $sb, $sb.Capacity)
        $title = $sb.ToString()
        if ($title.Length -gt 60) { $title = $title.Substring(0, 60) + '…' }
        return "$name `"$title`""
    } catch { return '(取得失敗)' }
}

# Safety net: whatever we last changed, put it back when the port dies.
$script:lastChange = $null   # @{ hwnd = <IntPtr>; open = <int>; conv = <int> }

function Read-Exactly([int]$count) {
    $buf = New-Object byte[] $count
    $off = 0
    while ($off -lt $count) {
        $n = $stdin.Read($buf, $off, $count - $off)
        if ($n -le 0) { return $null }   # EOF - browser closed the port
        $off += $n
    }
    return $buf
}

function Read-Message {
    $lenBuf = Read-Exactly 4
    if ($null -eq $lenBuf) { return $null }
    $len = [BitConverter]::ToInt32($lenBuf, 0)
    if ($len -le 0 -or $len -gt 1048576) { return $null }
    $body = Read-Exactly $len
    if ($null -eq $body) { return $null }
    return [Text.Encoding]::UTF8.GetString($body)
}

function Write-Message([string]$json) {
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $stdout.Write([BitConverter]::GetBytes([int]$bytes.Length), 0, 4)
    $stdout.Write($bytes, 0, $bytes.Length)
    $stdout.Flush()
}

# hwnd 0 means "whatever window is in the foreground right now".
function Resolve-ImeWnd([int64]$hwnd) {
    $target = if ($hwnd -eq 0) { [ImeNative]::GetForegroundWindow() } else { [IntPtr]$hwnd }
    if ($target -eq [IntPtr]::Zero) { return @{ target = [IntPtr]::Zero; ime = [IntPtr]::Zero } }
    return @{ target = $target; ime = [ImeNative]::ImmGetDefaultIMEWnd($target) }
}

function Invoke-ImeControl([IntPtr]$imeWnd, [int]$cmd, [int]$value) {
    $result = [IntPtr]::Zero
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $ok = [ImeNative]::SendMessageTimeout(
        $imeWnd, $WM_IME_CONTROL, [IntPtr]$cmd, [IntPtr]$value,
        $SMTO_ABORTIFHUNG, $SEND_TIMEOUT_MS, [ref]$result)
    $sw.Stop()
    if ($ok -eq [IntPtr]::Zero) {   # timed out or window is hung
        Write-DebugLog ('    IMC 0x{0:X2} <- 0x{1:X4}  失敗/タイムアウト ({2}ms, 上限 {3}ms)' `
            -f $cmd, $value, $sw.ElapsedMilliseconds, $SEND_TIMEOUT_MS)
        return $null
    }
    Write-DebugLog ('    IMC 0x{0:X2} <- 0x{1:X4}  => 0x{2:X4} ({3}ms)' `
        -f $cmd, $value, [int]$result, $sw.ElapsedMilliseconds)
    return [int]$result
}

# 変換モードの書き込みは 2 種類あり、扱いが違う。
#
#   モード適用 ($exact = $false)
#     自分の 3 ビットだけを書き換え、非マスクビット（ROMAN = ローマ字入力 /
#     かな入力の別など）は現在値から引き継ぐ。ユーザー自身の設定を壊さないため。
#
#   状態の復帰 ($exact = $true)
#     捕獲した値をそのまま書き戻す。マスクに通してはいけない。適用中に非マスク
#     ビットが変わっていると、現在値側から引き継いだ値で上書きしてしまい、
#     ROMAN が落ちてローマ字入力からかな入力へ勝手に切り替わる。
function Set-ConversionBits([IntPtr]$imeWnd, [int]$current, [int]$value, [bool]$exact = $false) {
    $target = if ($exact) {
        $value
    } else {
        ($current -band (-bnot $CONV_MASK)) -bor ($value -band $CONV_MASK)
    }
    $kind = if ($exact) { '復帰' } else { '適用' }
    if ($target -eq $current) {
        Write-DebugLog ('    conv({0}): current=0x{1:X4} 要求=0x{2:X4} target=0x{3:X4} → 同値のため書き込みスキップ' `
            -f $kind, $current, $value, $target)
        return $true
    }
    Write-DebugLog ('    conv({0}): current=0x{1:X4} 要求=0x{2:X4} target=0x{3:X4}' -f $kind, $current, $value, $target)
    return $null -ne (Invoke-ImeControl $imeWnd $IMC_SETCONVERSIONMODE $target)
}

function Invoke-ImeRequest($req) {
    $cmd = [string]$req.cmd

    if ($cmd -eq 'ping') { return @{ ok = $true } }

    # ログ無効時に ConvertTo-Json / Get-Process を走らせないよう、引数の組み立てごと囲う。
    $logging = $null -ne $script:logPath
    if ($logging) { Write-DebugLog ('req  ' + ($req | ConvertTo-Json -Compress)) }

    $hwndIn = 0
    if ($null -ne $req.hwnd) { $hwndIn = [int64]$req.hwnd }
    $w = Resolve-ImeWnd $hwndIn

    if ($w.ime -eq [IntPtr]::Zero) {
        Write-DebugLog '  IME ウィンドウを取得できず'
        return @{ ok = $false; error = 'no IME window for target' }
    }
    if ($logging) {
        # hwnd 0 はフォアグラウンドに解決される。ここが Edge でなければ、
        # 別アプリの IME を書き換えていることになる。
        Write-DebugLog ('  target hwnd=0x{0:X} ime=0x{1:X} (要求 hwnd={2}) → {3}' -f
            [int64]$w.target, [int64]$w.ime, $hwndIn, (Get-WindowLabel $w.target))
    }

    $curOpen = Invoke-ImeControl $w.ime $IMC_GETOPENSTATUS 0
    if ($null -eq $curOpen) { return @{ ok = $false; error = 'IMC_GETOPENSTATUS timed out' } }
    $curConv = Invoke-ImeControl $w.ime $IMC_GETCONVERSIONMODE 0
    if ($null -eq $curConv) { return @{ ok = $false; error = 'IMC_GETCONVERSIONMODE timed out' } }

    if ($cmd -eq 'get') {
        return @{ ok = $true; hwnd = [int64]$w.target; open = $curOpen; conv = $curConv }
    }

    if ($cmd -ne 'set') { return @{ ok = $false; error = "unknown cmd: $cmd" } }

    $open = [int]$req.open

    # Resolve the requested conversion mode: a symbolic name from the extension
    # (apply), or a raw value when restoring a state we captured earlier.
    # どちらで来たかで書き方が変わるので取り違えないこと。
    $convValue = $null
    $convExact = $false
    if ($null -ne $req.conv) {
        $name = [string]$req.conv
        if (-not $CONV_BITS.ContainsKey($name)) {
            return @{ ok = $false; error = "unknown conv: $name" }
        }
        $convValue = [int]$CONV_BITS[$name]
    } elseif ($null -ne $req.convRaw) {
        $convValue = [int]$req.convRaw
        $convExact = $true
    }

    # Conversion-mode writes only stick while the IME is open, so sequence the
    # two writes around that: open first when turning on, conv first when turning off.
    if ($open -eq 1) {
        if ($curOpen -ne 1) { Invoke-ImeControl $w.ime $IMC_SETOPENSTATUS 1 | Out-Null }
        if ($null -ne $convValue) { Set-ConversionBits $w.ime $curConv $convValue $convExact | Out-Null }
    } else {
        if ($null -ne $convValue -and $curOpen -eq 1) {
            Set-ConversionBits $w.ime $curConv $convValue $convExact | Out-Null
        }
        if ($curOpen -ne 0) { Invoke-ImeControl $w.ime $IMC_SETOPENSTATUS 0 | Out-Null }
    }

    if ($req.restore) {
        $script:lastChange = $null
    } elseif ($null -eq $script:lastChange) {
        $script:lastChange = @{ hwnd = $w.target; open = $curOpen; conv = $curConv }
    }

    # 書いた結果が実際に残っているかを読み直す。書き込みが受理されたのに
    # 反映されない（TSF 側で捨てられる）のか、そもそも書いていないのかを分ける。
    # 直後と少し待った後の 2 回読むのは、TSF が非同期に反映する場合に
    # 「拒否された」と誤読しないため。参照スクリプトが 1.2 秒待つのと同じ理由。
    if ($null -ne $script:logPath) {
        $afterOpen = Invoke-ImeControl $w.ime $IMC_GETOPENSTATUS 0
        $afterConv = Invoke-ImeControl $w.ime $IMC_GETCONVERSIONMODE 0
        Write-DebugLog ('  結果(直後): open {0} -> {1} / conv 0x{2:X4} -> 0x{3:X4}' -f
            $curOpen, $afterOpen, $curConv, $afterConv)

        Start-Sleep -Milliseconds 250
        $lateOpen = Invoke-ImeControl $w.ime $IMC_GETOPENSTATUS 0
        $lateConv = Invoke-ImeControl $w.ime $IMC_GETCONVERSIONMODE 0
        Write-DebugLog ('  結果(250ms後): open {0} / conv 0x{1:X4}' -f $lateOpen, $lateConv)
    }

    return @{ ok = $true; hwnd = [int64]$w.target; previous = $curOpen; previousConv = $curConv }
}

try {
    while ($true) {
        $raw = Read-Message
        if ($null -eq $raw) { break }

        $id = $null
        try {
            $req = $raw | ConvertFrom-Json
            $id = $req.id
            $resp = Invoke-ImeRequest $req
        } catch {
            $resp = @{ ok = $false; error = "$_" }
        }
        $resp['id'] = $id
        Write-Message ($resp | ConvertTo-Json -Compress)
    }
}
finally {
    # Port died (service worker evicted, extension disabled, browser closed).
    # Never strand the user with the IME in a state they did not choose.
    if ($null -ne $script:lastChange) {
        $ime = [ImeNative]::ImmGetDefaultIMEWnd($script:lastChange.hwnd)
        if ($ime -ne [IntPtr]::Zero) {
            $now = Invoke-ImeControl $ime $IMC_GETCONVERSIONMODE 0
            # 復帰なので exact。マスクに通すと ROMAN などが落ちる。
            if ($null -ne $now) { Set-ConversionBits $ime $now $script:lastChange.conv $true | Out-Null }
            Invoke-ImeControl $ime $IMC_SETOPENSTATUS $script:lastChange.open | Out-Null
        }
    }
}
