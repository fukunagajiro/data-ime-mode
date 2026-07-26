# Registers the native messaging host for Microsoft Edge (current user only).
#
#   powershell -ExecutionPolicy Bypass -File install.ps1 -ExtensionId <32文字のID>
#
# 拡張機能IDは edge://extensions で「開発者モード」をオンにし、
# このリポジトリの extension\ フォルダを「展開して読み込み」した後に表示されます。

param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-p]{32}$')]
    [string]$ExtensionId,

    [string]$HostName = 'com.example.data_ime_mode'
)

$ErrorActionPreference = 'Stop'

$dir      = $PSScriptRoot
$batPath  = Join-Path $dir 'ime-host.bat'
$manPath  = Join-Path $dir "$HostName.json"

if (-not (Test-Path $batPath)) { throw "ime-host.bat が見つかりません: $batPath" }

$manifest = [ordered]@{
    name            = $HostName
    description     = 'data-ime-mode native host'
    path            = $batPath
    type            = 'stdio'
    allowed_origins = @("chrome-extension://$ExtensionId/")
}

# Chromium は BOM 付き JSON を拒否するので UTF8Encoding($false) で書く
$json = $manifest | ConvertTo-Json -Depth 4
[IO.File]::WriteAllText($manPath, $json, (New-Object Text.UTF8Encoding($false)))

$key = "HKCU:\Software\Microsoft\Edge\NativeMessagingHosts\$HostName"

# フォルダをコピー / 名前変更した場合、前の場所の登録が残ったままになる。
# 黙って上書きすると「直したはずのコードが動かない」の原因が見えないので控えておく。
$previous = $null
if (Test-Path $key) {
    $previous = (Get-ItemProperty -Path $key -ErrorAction SilentlyContinue).'(default)'
}

New-Item -Path $key -Force | Out-Null
New-ItemProperty -Path $key -Name '(default)' -Value $manPath -PropertyType String -Force | Out-Null

Write-Host "登録しました。" -ForegroundColor Green
Write-Host "  manifest : $manPath"
Write-Host "  registry : $key"

if ($previous -and $previous -ne $manPath) {
    Write-Host ""
    Write-Host "以前の登録を別の場所から付け替えました:" -ForegroundColor Yellow
    Write-Host "  旧 : $previous"
    Write-Host "  新 : $manPath"
    Write-Host "旧フォルダが残っている場合、edge://extensions に読み込み済みの拡張機能も" -ForegroundColor Yellow
    Write-Host "そちらを指している可能性があります。読み込み直して ID を確認してください。" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Edge を完全に終了してから起動し直してください（タスクトレイの常駐も含む）。"
