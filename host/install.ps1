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
New-Item -Path $key -Force | Out-Null
New-ItemProperty -Path $key -Name '(default)' -Value $manPath -PropertyType String -Force | Out-Null

Write-Host "登録しました。" -ForegroundColor Green
Write-Host "  manifest : $manPath"
Write-Host "  registry : $key"
Write-Host ""
Write-Host "Edge を完全に終了してから起動し直してください（タスクトレイの常駐も含む）。"
