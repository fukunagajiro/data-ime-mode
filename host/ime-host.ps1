#requires -Version 5.1
# Native Messaging host for the data-ime-mode extension.
# Speaks Chromium's stdio protocol (4-byte native-order length prefix + UTF-8 JSON)
# and drives the IME open state / conversion mode of a target window via WM_IME_CONTROL.

$ErrorActionPreference = 'Stop'

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class ImeNative {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("imm32.dll")]  public static extern IntPtr ImmGetDefaultIMEWnd(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern IntPtr SendMessageTimeout(
        IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam,
        uint fuFlags, uint uTimeout, out IntPtr lpdwResult);
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
    $ok = [ImeNative]::SendMessageTimeout(
        $imeWnd, $WM_IME_CONTROL, [IntPtr]$cmd, [IntPtr]$value,
        $SMTO_ABORTIFHUNG, $SEND_TIMEOUT_MS, [ref]$result)
    if ($ok -eq [IntPtr]::Zero) { return $null }   # timed out or window is hung
    return [int]$result
}

# Rewrites only the bits we own, leaving the user's ROMAN setting etc. alone.
function Set-ConversionBits([IntPtr]$imeWnd, [int]$current, [int]$bits) {
    $target = ($current -band (-bnot $CONV_MASK)) -bor ($bits -band $CONV_MASK)
    if ($target -eq $current) { return $true }
    return $null -ne (Invoke-ImeControl $imeWnd $IMC_SETCONVERSIONMODE $target)
}

function Invoke-ImeRequest($req) {
    $cmd = [string]$req.cmd

    if ($cmd -eq 'ping') { return @{ ok = $true } }

    $hwndIn = 0
    if ($null -ne $req.hwnd) { $hwndIn = [int64]$req.hwnd }
    $w = Resolve-ImeWnd $hwndIn

    if ($w.ime -eq [IntPtr]::Zero) {
        return @{ ok = $false; error = 'no IME window for target' }
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

    # Resolve the requested conversion bits: symbolic name from the extension,
    # or a raw value when restoring a state we captured earlier.
    $bits = $null
    if ($null -ne $req.conv) {
        $name = [string]$req.conv
        if (-not $CONV_BITS.ContainsKey($name)) {
            return @{ ok = $false; error = "unknown conv: $name" }
        }
        $bits = [int]$CONV_BITS[$name]
    } elseif ($null -ne $req.convRaw) {
        $bits = [int]$req.convRaw
    }

    # Conversion-mode writes only stick while the IME is open, so sequence the
    # two writes around that: open first when turning on, conv first when turning off.
    if ($open -eq 1) {
        if ($curOpen -ne 1) { Invoke-ImeControl $w.ime $IMC_SETOPENSTATUS 1 | Out-Null }
        if ($null -ne $bits) { Set-ConversionBits $w.ime $curConv $bits | Out-Null }
    } else {
        if ($null -ne $bits -and $curOpen -eq 1) { Set-ConversionBits $w.ime $curConv $bits | Out-Null }
        if ($curOpen -ne 0) { Invoke-ImeControl $w.ime $IMC_SETOPENSTATUS 0 | Out-Null }
    }

    if ($req.restore) {
        $script:lastChange = $null
    } elseif ($null -eq $script:lastChange) {
        $script:lastChange = @{ hwnd = $w.target; open = $curOpen; conv = $curConv }
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
            if ($null -ne $now) { Set-ConversionBits $ime $now $script:lastChange.conv | Out-Null }
            Invoke-ImeControl $ime $IMC_SETOPENSTATUS $script:lastChange.open | Out-Null
        }
    }
}
