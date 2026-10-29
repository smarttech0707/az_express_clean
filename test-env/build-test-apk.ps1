# Construit l'APK de TEST (debug, com.azexpress.app.test) relié au projet Firebase de TEST.
# Il s'installe à côté de l'application de production sans la remplacer.
#
# Prérequis (une seule fois, par vous) :
#   1. test-env\dart-defines.test.json  (copie de env\dart-defines.test.example.json renseignée)
#   2. le google-services.json du projet de TEST, app Android « com.azexpress.app.test »
#      (Console Firebase du projet de test > Paramètres > Vos applications)
#
# Usage :  powershell -ExecutionPolicy Bypass -File test-env\build-test-apk.ps1 -GoogleServices C:\chemin\google-services.json
param(
  [Parameter(Mandatory = $true)][string]$GoogleServices
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$target = Join-Path $root 'android\app\src\debug\google-services.json'
$defines = Join-Path $root 'test-env\dart-defines.test.json'

if (Test-Path $target) { throw "Fichier déjà présent : $target (build de test précédent interrompu ? vérifiez puis supprimez-le)." }
if (-not (Test-Path $GoogleServices)) { throw "google-services.json introuvable : $GoogleServices" }

try {
  New-Item -ItemType Directory -Force (Split-Path $target) | Out-Null
  Copy-Item $GoogleServices $target
  # 1) Garde-fou : refuse tout ce qui référence la production.
  node test-env\verify-isolation.js --defines test-env\dart-defines.test.json --google-services android\app\src\debug\google-services.json
  if ($LASTEXITCODE -ne 0) { throw 'Isolation non validée : build annulé.' }
  # 2) Identifiant d'application de test (propriété Gradle lue par build.gradle.kts).
  $env:ORG_GRADLE_PROJECT_azTestSuffix = '.test'
  flutter build apk --debug "--dart-define-from-file=$defines"
  if ($LASTEXITCODE -ne 0) { throw 'flutter build a échoué.' }
  Write-Host "APK de test : $root\build\app\outputs\flutter-apk\app-debug.apk"
}
finally {
  Remove-Item Env:ORG_GRADLE_PROJECT_azTestSuffix -ErrorAction SilentlyContinue
  # Le fichier temporaire est retiré : les builds debug suivants ne visent pas le projet de test par accident.
  if (Test-Path $target) { Remove-Item $target -Force }
}
