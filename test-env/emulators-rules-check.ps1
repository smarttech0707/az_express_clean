# Vérifie les règles Firestore et Storage de firestore.rules / storage.rules dans des émulateurs temporaires
# (projet demo-az-express, configuration test-env\firebase.emulators.json). Démarre et arrête ses propres
# émulateurs Firestore + Storage : arrêtez emulators-start.ps1 avant (mêmes ports).
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
node test-env\stage-functions.js
if ($LASTEXITCODE -ne 0) { throw 'Préparation échouée.' }
$scripts = (Get-Content package.json -Raw | ConvertFrom-Json).scripts
$cfgArgs = @('--config', 'test-env/firebase.emulators.json', '--project', 'demo-az-express')

foreach ($name in 'test:rules', 'test:storage') {
  # La commande « node --test … » est celle de package.json (une seule source de vérité).
  $inner = [regex]::Match($scripts.$name, '"(node --test .+)"\s*$').Groups[1].Value
  if (-not $inner) { throw "Commande introuvable pour $name" }
  Write-Host "== $name (projet demo-az-express) ==" -ForegroundColor Cyan
  $only = if ($name -eq 'test:rules') { 'firestore' } else { 'firestore,storage' }
  firebase emulators:exec @cfgArgs --only $only $inner
  if ($LASTEXITCODE -ne 0) { throw "$name : des tests de règles ont échoué." }
}
Write-Host 'Règles Firestore et Storage vérifiées dans les émulateurs.' -ForegroundColor Green
