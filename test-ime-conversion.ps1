# 変換モード（ひらがな / 全角カタカナ / 半角カタカナ）の切り替えが
# Edge に対して効くかどうかだけを確認する単体テスト。拡張機能は不要。
#
#   powershell -ExecutionPolicy Bypass -File test-ime-conversion.ps1

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class ImeConv {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("imm32.dll")]  public static extern IntPtr ImmGetDefaultIMEWnd(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
}
"@

$WM_IME_CONTROL        = 0x0283
$IMC_GETCONVERSIONMODE = 0x0001
$IMC_SETCONVERSIONMODE = 0x0002
$IMC_GETOPENSTATUS     = 0x0005
$IMC_SETOPENSTATUS     = 0x0006

$MASK = 0x000B   # NATIVE | KATAKANA | FULLSHAPE
$modes = [ordered]@{
    'ひらがな'     = 0x0009
    '全角カタカナ' = 0x000B
    '半角カタカナ' = 0x0003
}

Write-Host '5秒以内に Edge の入力欄をクリックしてください（IME はオン/オフどちらでも可）'
Start-Sleep -Seconds 5

$hwnd = [ImeConv]::GetForegroundWindow()
$ime  = [ImeConv]::ImmGetDefaultIMEWnd($hwnd)
Write-Host "IME ウィンドウ: $ime"
if ($ime -eq [IntPtr]::Zero) { Write-Host '取得失敗。ここで詰みです。' -ForegroundColor Red; exit 1 }

$origOpen = [int][ImeConv]::SendMessage($ime, $WM_IME_CONTROL, [IntPtr]$IMC_GETOPENSTATUS, [IntPtr]0)
$origConv = [int][ImeConv]::SendMessage($ime, $WM_IME_CONTROL, [IntPtr]$IMC_GETCONVERSIONMODE, [IntPtr]0)
Write-Host ("元の状態: open={0} conv=0x{1:X4}" -f $origOpen, $origConv)

# 変換モードは IME が開いていないと反映されない
[ImeConv]::SendMessage($ime, $WM_IME_CONTROL, [IntPtr]$IMC_SETOPENSTATUS, [IntPtr]1) | Out-Null

foreach ($name in $modes.Keys) {
    $target = ($origConv -band (-bnot $MASK)) -bor $modes[$name]
    [ImeConv]::SendMessage($ime, $WM_IME_CONTROL, [IntPtr]$IMC_SETCONVERSIONMODE, [IntPtr]$target) | Out-Null
    Start-Sleep -Milliseconds 1200
    $now = [int][ImeConv]::SendMessage($ime, $WM_IME_CONTROL, [IntPtr]$IMC_GETCONVERSIONMODE, [IntPtr]0)
    $ok  = ($now -band $MASK) -eq $modes[$name]
    $mark = if ($ok) { 'OK  ' } else { 'NG  ' }
    Write-Host ("{0}{1,-14} 期待=0x{2:X4} 実際=0x{3:X4}" -f $mark, $name, $target, $now) `
        -ForegroundColor $(if ($ok) { 'Green' } else { 'Red' })
}

# 後始末
[ImeConv]::SendMessage($ime, $WM_IME_CONTROL, [IntPtr]$IMC_SETCONVERSIONMODE, [IntPtr]$origConv) | Out-Null
[ImeConv]::SendMessage($ime, $WM_IME_CONTROL, [IntPtr]$IMC_SETOPENSTATUS, [IntPtr]$origOpen) | Out-Null
Write-Host '元の状態に戻しました。'
Write-Host ''
Write-Host '各モードで 1.2 秒停止します。タスクバーの IME 表示が あ → ア → _ｱ と'
Write-Host '変化したかどうかも目視で確認してください（表示は IME の設定により異なります）。'
