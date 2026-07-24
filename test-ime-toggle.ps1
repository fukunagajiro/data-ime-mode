Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Ime {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("imm32.dll")]  public static extern IntPtr ImmGetDefaultIMEWnd(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
}
"@
"5秒以内にEdgeの入力欄をクリックし、IMEを「あ」にしてください"
Start-Sleep -Seconds 5
$hwnd = [Ime]::GetForegroundWindow()
$ime  = [Ime]::ImmGetDefaultIMEWnd($hwnd)
"IMEウィンドウ: $ime"                      # 0 なら取得失敗＝この時点で詰み
# 0x0283=WM_IME_CONTROL, 0x0005=IMC_GETOPENSTATUS, 0x0006=IMC_SETOPENSTATUS
"変更前: " + [Ime]::SendMessage($ime,0x0283,[IntPtr]0x0005,[IntPtr]0)
[Ime]::SendMessage($ime,0x0283,[IntPtr]0x0006,[IntPtr]0) | Out-Null
"変更後: " + [Ime]::SendMessage($ime,0x0283,[IntPtr]0x0005,[IntPtr]0)