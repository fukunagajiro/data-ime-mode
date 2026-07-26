# ime-host.ps1 の変換モード計算だけを単体で確認する。
# 実ソースから関数定義を AST で取り出し、Win32 呼び出しはスタブに差し替える。
# IME には一切触らない。
#
#   powershell -ExecutionPolicy Bypass -File test\host.test.ps1

param([string]$Source)

$ErrorActionPreference = 'Stop'

$src = if ($Source) { $Source } else { Join-Path $PSScriptRoot '..\host\ime-host.ps1' }
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    (Resolve-Path $src), [ref]$null, [ref]$null)

$fn = $ast.FindAll({
    $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $args[0].Name -eq 'Set-ConversionBits'
}, $true)
if ($fn.Count -ne 1) { throw "Set-ConversionBits が見つかりません (見つかった数: $($fn.Count))" }

# 依存をスタブ化してから、実物の関数定義を読み込む。
$script:written = $null
function Invoke-ImeControl($imeWnd, $cmd, $value) { $script:written = $value; return 0 }
function Write-DebugLog($msg) { }
$CONV_MASK = 0x000B

Invoke-Expression $fn[0].Extent.Text

$results = @()

function Show($v) {
    if ($null -eq $v) { return '書き込みなし' }
    return ('0x{0:X4}' -f [int]$v)
}

function Check([string]$name, [int]$current, [int]$value, [bool]$exact, $expectWrite) {
    $script:written = $null
    Set-ConversionBits ([IntPtr]::Zero) $current $value $exact | Out-Null
    $actual = $script:written
    $ok = if ($null -eq $expectWrite) { $null -eq $actual } else { $actual -eq $expectWrite }
    $script:results += [pscustomobject]@{
        Name     = $name
        Ok       = $ok
        Expected = (Show $expectWrite)
        Actual   = (Show $actual)
    }
}

# --- 適用: 自分の 3 ビットだけ書き換え、ROMAN などは現在値から引き継ぐ -------

Check ' 適用 ひらがな: 既にひらがな (ROMAN 有) なら書かない' 0x0019 0x0009 $false $null
Check ' 適用 全角カナ: ROMAN を保ったまま KATAKANA を立てる'   0x0019 0x000B $false 0x001B
Check ' 適用 半角カナ: ROMAN を保ったまま FULLSHAPE を落とす'  0x0019 0x0003 $false 0x0013
Check ' 適用 全角カナ: ROMAN が無ければ付けない'               0x0009 0x000B $false 0x000B

# --- 復帰: 捕獲した値をそのまま書き戻す -------------------------------------
#
# ここをマスクに通すと、適用中に非マスクビットが変わっていた場合に取り違える。
# 実際にログで観測した壊れ方: convRaw=0x0019 を要求したのに 0x0009 が書かれ、
# ROMAN が落ちてローマ字入力からかな入力へ勝手に切り替わっていた。

Check '*復帰 ROMAN を含む値を欠けずに書き戻す'      0x0003 0x0019 $true 0x0019
Check '*復帰 現在値と同じなら書かない'              0x0019 0x0019 $true $null
Check '*復帰 変換モード無し (0x0000) へ戻せる'      0x0009 0x0000 $true 0x0000
Check '*復帰 非マスクビットのみ異なる場合も書き直す' 0x0009 0x0019 $true 0x0019

$bad = 0
foreach ($r in $results) {
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
Write-Host ("{0}/{1} passed" -f ($results.Count - $bad), $results.Count)
if ($bad) { exit 1 }
