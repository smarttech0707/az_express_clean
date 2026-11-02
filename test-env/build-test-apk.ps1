# Construit l'APK de TEST (debug, com.azexpress.app.test) relie au projet Firebase de TEST.
# Il s'installe a cote de l'application de production sans la remplacer.
#
# Prerequis (une seule fois, par vous) :
#   1. test-env\dart-defines.test.json  (copie de env\dart-defines.test.example.json renseignee)
#   2. le google-services.json du projet de TEST, app Android "com.azexpress.app.test"
#      (Console Firebase du projet de test > Parametres > Vos applications)
#
# Cle Google Maps : lib\constants\maps_key.dart (versionne) contient la cle de PRODUCTION. Les imports conditionnels Dart
# n'honorent pas --dart-define dans cette chaine d'outils (verifie le 2026-10-31) : ce script REMPLACE temporairement le fichier
# par la version de test (maps_key_test.dart), verifie, construit, puis RESTAURE l'original (sauvegarde hors depot).
# Une cle de test eventuelle se passe par "TEST_MAPS_API_KEY" dans le fichier de dart-defines.
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
$mapsFile = Join-Path $root 'lib\constants\maps_key.dart'
$mapsTest = Join-Path $root 'lib\constants\maps_key_test.dart'
$mapsBackup = Join-Path $env:TEMP 'az_maps_key_prod_backup.dart'

if (Test-Path $target) { throw "Fichier deja present : $target (build de test precedent interrompu ? verifiez puis supprimez-le)." }
if (Test-Path $mapsBackup) { throw "Sauvegarde de maps_key.dart deja presente : $mapsBackup (build precedent interrompu ? restaurez lib\constants\maps_key.dart depuis ce fichier, puis supprimez-le)." }
if (-not (Test-Path $GoogleServices)) { throw "google-services.json introuvable : $GoogleServices" }
if (-not (Test-Path $mapsTest)) { throw "maps_key_test.dart introuvable : $mapsTest" }

$swapped = $false
try {
  New-Item -ItemType Directory -Force (Split-Path $target) | Out-Null
  Copy-Item $GoogleServices $target

  # 1) Remplacement de la cle Maps de production (sauvegarde hors depot, restauration garantie dans finally).
  Copy-Item $mapsFile $mapsBackup
  $swapped = $true
  Copy-Item $mapsTest $mapsFile -Force

  # 2) Garde-fou : refuse tout ce qui reference la production, y compris une cle Maps de production restante.
  node test-env\verify-isolation.js --defines test-env\dart-defines.test.json --google-services android\app\src\debug\google-services.json --maps-swapped
  if ($LASTEXITCODE -ne 0) { throw 'Isolation non validee : build annule.' }

  # 3) Identifiant d'application de test (propriete Gradle lue par build.gradle.kts) + cle Maps de test eventuelle.
  # Passe par --android-project-arg (-P) : les variables d'environnement ORG_GRADLE_PROJECT_* ne sont PAS transmises a Gradle par
  # flutter (verifie le 2026-10-31 : le build visait alors com.azexpress.app et aurait lu MAPS_API_KEY dans android\local.properties).
  $projArgs = @('--android-project-arg=azTestSuffix=.test')
  $testMapsKey = (Get-Content $defines -Raw | ConvertFrom-Json).TEST_MAPS_API_KEY
  # Propriete toujours definie (vide sans cle de test) : le manifeste ne retombe jamais sur la cle de production de local.properties.
  $projArgs += "--android-project-arg=azTestMapsKey=$testMapsKey"
  flutter build apk --debug "--dart-define-from-file=$defines" @projArgs
  if ($LASTEXITCODE -ne 0) { throw 'flutter build a echoue.' }

  # 4) Controle apres build : la cle de production ne doit figurer dans aucun artefact lisible.
  $blobs = @(Get-ChildItem (Join-Path $root 'build\app\intermediates\flutter') -Recurse -Filter 'kernel_blob.bin' -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
  if ($blobs.Count -gt 0) {
    node test-env\check-no-prod-maps-key.js $mapsBackup $blobs
    if ($LASTEXITCODE -ne 0) { throw 'La cle Google Maps de production est presente dans le build : APK a ne pas utiliser.' }
  } else { Write-Warning 'kernel_blob.bin introuvable : controle post-build de la cle Maps non effectue.' }

  # 5) Controle de l'APK final : package, cle Maps de production (UTF-8 et UTF-16), references de production, cles inconnues.
  $apk = Join-Path $root 'build\app\outputs\flutter-apk\app-debug.apk'
  if (-not (Test-Path $apk)) { throw "APK introuvable : $apk" }
  $aapt2 = Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Android\Sdk\build-tools') -Recurse -Filter 'aapt2.exe' -ErrorAction SilentlyContinue | Sort-Object FullName | Select-Object -Last 1
  if ($aapt2) {
    $badging = & $aapt2.FullName dump badging $apk | Select-String -Pattern '^package:' | Select-Object -First 1
    Write-Host $badging.Line
    if ($badging.Line -notmatch "name='com\.azexpress\.app\.test'") { throw 'Le package de l APK n est pas com.azexpress.app.test.' }
  } else { Write-Warning 'aapt2 introuvable : package non verifie.' }
  $extract = Join-Path $env:TEMP 'az_apk_audit'
  if (Test-Path $extract) { Remove-Item $extract -Recurse -Force }
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  [System.IO.Compression.ZipFile]::ExtractToDirectory($apk, $extract)
  try {
    node test-env\check-no-prod-maps-key.js $mapsBackup $extract
    if ($LASTEXITCODE -ne 0) { throw 'La cle Google Maps de production est presente dans l APK : a ne pas utiliser.' }
    node test-env\audit-apk-content.js $extract $GoogleServices
    if ($LASTEXITCODE -ne 0) { throw 'Audit de l APK : reference de production ou cle inconnue.' }
  } finally { Remove-Item $extract -Recurse -Force -ErrorAction SilentlyContinue }
  Write-Host "APK de test : $apk"
}
finally {
  # Le fichier temporaire est retire : les builds debug suivants ne visent pas le projet de test par accident.
  if (Test-Path $target) { Remove-Item $target -Force }
  # Restauration de la cle de production dans maps_key.dart, puis suppression de la sauvegarde si l'empreinte correspond.
  if ($swapped -and (Test-Path $mapsBackup)) {
    Copy-Item $mapsBackup $mapsFile -Force
    $same = (Get-FileHash $mapsBackup).Hash -eq (Get-FileHash $mapsFile).Hash
    if ($same) { Remove-Item $mapsBackup -Force } else { Write-Error "Restauration de maps_key.dart non verifiee : sauvegarde conservee dans $mapsBackup" }
  }
}
