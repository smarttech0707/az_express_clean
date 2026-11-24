# Construit l'APK de TEST (debug, com.azexpress.app.test) relie au projet Firebase de PREPRODUCTION.
# Ce script n'est qu'un wrapper : toute la logique (choix du projet, validation Firebase, APP_BUILD_NUMBER, FCM, cle Maps,
# controles de l'APK) est dans scripts\build_preprod.py. Il s'installe a cote de l'application de production sans la remplacer.
#
# Prerequis (une seule fois, par vous) :
#   1. test-env\dart-defines.test.json  (copie de env\dart-defines.test.example.json renseignee)
#   2. le google-services.json du projet de preproduction, app Android "com.azexpress.app.test"
#
# Usage :  powershell -ExecutionPolicy Bypass -File test-env\build-test-apk.ps1 -GoogleServices C:\chemin\google-services.json
#          (-CheckOnly : valide la configuration sans compiler ; -MapsDisabled : build sans Google Maps, a choisir explicitement
#           si le fichier de dart-defines ne contient pas TEST_MAPS_API_KEY)
param(
  [Parameter(Mandatory = $true)][string]$GoogleServices,
  [switch]$CheckOnly,
  [switch]$MapsDisabled
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$defines = Join-Path $root 'test-env\dart-defines.test.json'
$engineArgs = @('scripts\build_preprod.py', 'apk', '--config', $defines, '--google-services', $GoogleServices)
if ($CheckOnly) { $engineArgs += '--check-only' }
if ($MapsDisabled) { $engineArgs += '--maps-disabled' }
if (-not (Get-Command py -ErrorAction SilentlyContinue)) { throw 'Lanceur Python "py" introuvable : installez Python pour Windows (python.org) avant de relancer.' }
py @engineArgs
if ($LASTEXITCODE -ne 0) { throw 'build_preprod.py a refuse ou echoue : voir le message ci-dessus.' }
