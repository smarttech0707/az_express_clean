# Installe l'APK de TEST sur les deux téléphones branchés (Samsung SM-A115F, Infinix X6525D).
# Ne touche pas à l'application de production (identifiant différent : com.azexpress.app.test).
#
# Usage :  powershell -ExecutionPolicy Bypass -File test-env\install-test-apk.ps1
param(
  [string]$Apk = 'build\app\outputs\flutter-apk\app-debug.apk'
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$adb = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
if (-not (Test-Path $adb)) { throw "adb introuvable : $adb (installez les Platform-Tools du SDK Android)." }
if (-not (Test-Path $Apk)) { throw "APK introuvable : $Apk (lancez d'abord build-test-apk.ps1)." }

$expected = @('SM-A115F', 'X6525D')
$serials = & $adb devices | Select-Object -Skip 1 | Where-Object { $_ -match '\sdevice$' } | ForEach-Object { ($_ -split '\s+')[0] }
if (-not $serials) { throw 'Aucun appareil autorisé. Activez le débogage USB et acceptez la clé RSA sur chaque téléphone.' }

foreach ($serial in $serials) {
  $model = (& $adb -s $serial shell getprop ro.product.model).Trim()
  $known = $expected -contains $model
  Write-Host "[$serial] modèle $model $(if ($known) { '(attendu)' } else { '(NON prévu : ignoré)' })"
  if (-not $known) { continue }
  & $adb -s $serial install -r $Apk
  if ($LASTEXITCODE -ne 0) { throw "Installation échouée sur $serial ($model)." }
  & $adb -s $serial shell pm list packages com.azexpress.app | Out-Host
}
Write-Host 'Terminé. Lancez « AZ Express » de test (paquet com.azexpress.app.test).'
