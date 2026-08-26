param([string]$HostName = 'io.github.fukunagajiro.data_ime_mode')

$ErrorActionPreference = 'Stop'

$key = "HKCU:\Software\Microsoft\Edge\NativeMessagingHosts\$HostName"
if (Test-Path $key) {
    Remove-Item -Path $key -Recurse -Force
    Write-Host "レジストリキーを削除しました: $key"
} else {
    Write-Host "レジストリキーは見つかりませんでした: $key"
}

$manPath = Join-Path $PSScriptRoot "$HostName.json"
if (Test-Path $manPath) {
    Remove-Item -Path $manPath -Force
    Write-Host "マニフェストを削除しました: $manPath"
}
