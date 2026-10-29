# Écrit les données fictives dans les émulateurs en cours d'exécution (jamais ailleurs) :
# 1 client, 2 livreurs, 1 admin, 1 vendeur, portefeuilles de test, produits, zones, commandes fictives.
#
# Usage :  powershell -ExecutionPolicy Bypass -File test-env\emulators-seed.ps1
param(
  [string]$Password   # facultatif ; sinon demandé (jamais écrit sur disque)
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

if (-not $Password) {
  $secure = Read-Host 'Mot de passe des comptes de test (12 caractères minimum)' -AsSecureString
  $Password = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
}
# Cibles locales uniquement.
$env:FIRESTORE_EMULATOR_HOST = '127.0.0.1:8080'
$env:FIREBASE_AUTH_EMULATOR_HOST = '127.0.0.1:9099'
$env:GCLOUD_PROJECT = 'demo-az-express'
Remove-Item Env:GOOGLE_APPLICATION_CREDENTIALS -ErrorAction SilentlyContinue
$env:AZ_TEST_PASSWORD = $Password
try {
  node test-env\seed-test-data.js --project demo-az-express --emulator
  if ($LASTEXITCODE -ne 0) { throw 'Seed échoué (les émulateurs sont-ils démarrés ?).' }
}
finally { Remove-Item Env:AZ_TEST_PASSWORD -ErrorAction SilentlyContinue }
