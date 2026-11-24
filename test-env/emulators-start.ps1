# Démarre l'Emulator Suite (Auth, Firestore, Functions, Storage, UI) pour le projet LOCAL demo-az-express.
# Aucun projet Firebase réel n'est utilisé ; `firebase use` n'est jamais appelé ; .firebaserc n'est pas modifié.
#
# Usage :  powershell -ExecutionPolicy Bypass -File test-env\emulators-start.ps1 [-Persist]
param(
  [switch]$Persist   # conserve les données entre deux démarrages (test-env\.emulator-data, ignoré par git)
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
$ProjectId = 'demo-az-express'
$pidFile = Join-Path $PSScriptRoot '.emulators.pid'
$logDir = Join-Path $PSScriptRoot 'runtime'
$ports = 4000, 4400, 4500, 5001, 8080, 9099, 9150, 9199

if (Test-Path $pidFile) { throw "Des émulateurs semblent déjà lancés (PID dans $pidFile). Exécutez emulators-stop.ps1 d'abord." }
$busy = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { $ports -contains $_.LocalPort }
if ($busy) { throw ("Ports déjà utilisés : " + (($busy | Select-Object -ExpandProperty LocalPort -Unique) -join ', ')) }

# 1) Aucun secret ni identifiant externe hérité du shell : retirés pour ce processus et ses enfants.
foreach ($name in 'ANTHROPIC_API_KEY','OPENAI_API_KEY','GEMINI_API_KEY','DEEPSEEK_API_KEY','MISTRAL_API_KEY','GROQ_API_KEY',
                  'FEEXPAY_TOKEN','FEEXPAY_WEBHOOK_SECRET','FEEXPAY_SHOP_ID','GOOGLE_APPLICATION_CREDENTIALS','FIREBASE_TOKEN',
                  'ORANGE_SMS_CLIENT_ID','ORANGE_SMS_CLIENT_SECRET','DELIVERY_SMS_ENABLED','DELIVERY_SMS_PROVIDER') {
  Remove-Item "Env:$name" -ErrorAction SilentlyContinue
}
# Identifiants Google par défaut (gcloud ADC) masqués : le CLI les signalerait comme accès « production ».
$emptyGcloud = Join-Path $logDir 'gcloud-empty'
New-Item -ItemType Directory -Force $emptyGcloud | Out-Null
$env:CLOUDSDK_CONFIG = $emptyGcloud
$env:GCLOUD_PROJECT = $ProjectId
$env:GOOGLE_CLOUD_PROJECT = $ProjectId

# 2) Copie des fonctions SANS .env/secrets + garde de sortie réseau, puis vérification d'isolation.
node test-env\stage-functions.js
if ($LASTEXITCODE -ne 0) { throw 'Préparation des fonctions échouée.' }
node test-env\verify-emulator-isolation.js --strict-env
if ($LASTEXITCODE -ne 0) { throw 'Isolation non validée : émulateurs NON démarrés.' }

# 3) Démarrage (projet explicite, configuration séparée de firebase.json).
$fbArgs = "emulators:start --config test-env/firebase.emulators.json --project $ProjectId --only auth,firestore,functions,storage,ui"
if ($Persist) {
  # Premier démarrage : pas encore d'export à importer (le CLI refuse un dossier inexistant).
  if (Test-Path (Join-Path $PSScriptRoot '.emulator-data\firebase-export-metadata.json')) { $fbArgs += ' --import test-env/.emulator-data' }
  $fbArgs += ' --export-on-exit test-env/.emulator-data'
}
$proc = Start-Process -FilePath 'cmd.exe' -ArgumentList "/c firebase $fbArgs" -PassThru -WindowStyle Minimized `
  -RedirectStandardOutput (Join-Path $logDir 'emulators.log') -RedirectStandardError (Join-Path $logDir 'emulators.err.log')
Set-Content -Path $pidFile -Value $proc.Id

# 4) Attente de disponibilité (hub 4400, puis Functions 5001).
$deadline = (Get-Date).AddSeconds(240)
$ready = $false
while ((Get-Date) -lt $deadline) {
  Start-Sleep -Seconds 3
  if ($proc.HasExited) { throw "Les émulateurs se sont arrêtés (voir $logDir\emulators.log)." }
  try {
    $info = Invoke-RestMethod -Uri 'http://127.0.0.1:4400/emulators' -TimeoutSec 3
    if ($info.PSObject.Properties.Name -contains 'functions' -and $info.PSObject.Properties.Name -contains 'storage') { $ready = $true; break }
  } catch { }
}
if (-not $ready) { throw "Délai dépassé (voir $logDir\emulators.log)." }

$lan = Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' } |
  ForEach-Object { $_.IPv4Address.IPAddress } | Where-Object { $_ -match '^(10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)' } | Select-Object -First 1
Write-Host ''
Write-Host "Émulateurs prêts (projet $ProjectId)." -ForegroundColor Green
Write-Host '  Interface   : http://127.0.0.1:4000'
Write-Host '  Auth 9099 · Firestore 8080 · Functions 5001 · Storage 9199'
Write-Host "  IP du PC (réseau local) pour les téléphones : $lan"
Write-Host '  Étape suivante : emulators-seed.ps1, puis build-emulator-apk.ps1 -EmulatorHost <IP>'
