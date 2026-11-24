# Isole l'APK de test (com.azexpress.app.test) du reseau : tunnel USB vers les emulateurs + blocage reseau du paquet.
# Ne touche JAMAIS com.azexpress.app. Reversible : -Action Disable.
#
#   Enable  : adb reverse des 4 ports emulateurs (127.0.0.2 du telephone, adresse de repli : 127.0.0.1 serait reecrit en 10.0.2.2 par les plugins -> PC) et blocage reseau du paquet de test
#             (chaine OEM_DENY_3 d'Android) ; la boucle locale reste exemptee, donc seuls les emulateurs sont joignables.
#   Disable : retire les redirections et le blocage.
#   Status  : affiche l'etat.
param(
  [ValidateSet('Enable','Disable','Status')][string]$Action = 'Status',
  [string]$Serial = ''
)
$ErrorActionPreference = 'Stop'
$pkg = 'com.azexpress.app.test'
$ports = 5001, 8080, 9099, 9199
$adbArgs = @(); if ($Serial) { $adbArgs = @('-s', $Serial) }
function Invoke-Adb { & adb.exe @adbArgs @args }

if ($Action -eq 'Enable') {
  foreach ($p in $ports) { Invoke-Adb reverse "tcp:$p" "tcp:$p" | Out-Null }
  Invoke-Adb shell cmd connectivity set-chain3-enabled true | Out-Null
  Invoke-Adb shell cmd connectivity set-package-networking-enabled false $pkg | Out-Null
}
elseif ($Action -eq 'Disable') {
  Invoke-Adb shell cmd connectivity set-package-networking-enabled true $pkg | Out-Null
  Invoke-Adb shell cmd connectivity set-chain3-enabled false | Out-Null
  foreach ($p in $ports) { Invoke-Adb reverse --remove "tcp:$p" 2>$null | Out-Null }
}
Write-Host "--- reverse"; Invoke-Adb reverse --list
Write-Host "--- blocage reseau $pkg"; Invoke-Adb shell cmd connectivity get-package-networking-enabled $pkg
Write-Host "--- chain3"; Invoke-Adb shell cmd connectivity get-chain3-enabled
