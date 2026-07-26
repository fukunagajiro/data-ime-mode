# host.e2e.ps1 が使う対象ウィンドウ。テキストボックスを 1 つ持つだけ。
#
# 専用プロセスに分けているのは、SendMessageTimeout がターゲットスレッドの
# メッセージポンプに依存するため。ポンプが回っていないウィンドウ宛てだと
# SMTO_ABORTIFHUNG で即タイムアウトし、IME ではなく段取りを試すことになる。
#
# 単体で起動する用途はない。
param([string]$HandleFile)

Add-Type -AssemblyName System.Windows.Forms

$f = New-Object Windows.Forms.Form
$f.Text = 'data-ime-mode e2e target'
$f.Width = 420
$f.Height = 160
$f.TopMost = $true

$t = New-Object Windows.Forms.TextBox
$t.Dock = 'Fill'
$t.Multiline = $true
$f.Controls.Add($t)

# ハンドルは親が待っている。ウィンドウが出来てから渡す。
$f.Add_Shown({
    $t.Focus() | Out-Null
    [IO.File]::WriteAllText($HandleFile, $f.Handle.ToString())
})

[Windows.Forms.Application]::Run($f)
