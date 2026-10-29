# Construit l'APK de test relié UNIQUEMENT aux émulateurs du PC (aucune configuration de production dedans).
#
# Garanties :
#  - google-services.json FACTICE (projet demo-az-express, paquet com.azexpress.app.test) posé temporairement
#    dans android/app/src/debug : le plugin natif n'initialise jamais Firebase avec la production ; supprimé en fin
#    de build (même en cas d'échec). Le fichier de production n'est jamais lu ni modifié.
#  - Paquet imposé par -P (--android-project-arg) : com.azexpress.app.test, vérifié sur l'APK produit (aapt2).
#  - Aucun --dart-define-from-file=.env : les clés de production ne sont pas passées à Flutter.
#  - Clé Google Maps de production JAMAIS utilisée : cartes désactivées (clé vide) sauf -TestMapsKey explicite.
#  - Au démarrage, l'application refuse tout projet non « demo-… » et toute adresse non locale ; émulateurs
#    injoignables = appels en échec, jamais de repli sur la production.
#  - Contrôle final de l'APK : supprimé s'il contient un identifiant Firebase ou une clé Maps de production.
#
# Usage :  powershell -ExecutionPolicy Bypass -File test-env\build-emulator-apk.ps1 -EmulatorHost 10.131.214.87
param(
  [string]$EmulatorHost,
  [string]$TestMapsKey = ''   # clé Google Maps DE TEST explicitement autorisée ; vide = cartes désactivées
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

if (-not $EmulatorHost) {
  $EmulatorHost = Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' } |
    ForEach-Object { $_.IPv4Address.IPAddress } | Where-Object { $_ -match '^(10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)' } | Select-Object -First 1
}
if ($EmulatorHost -notmatch '^(127\.0\.0\.2|10\.\d{1,3}\.\d{1,3}\.\d{1,3}|192\.168\.\d{1,3}\.\d{1,3}|172\.(1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3})$') {
  throw "Adresse invalide « $EmulatorHost » : indiquez l'IP privée du PC (-EmulatorHost 192.168.x.x) ou 127.0.0.2 (tunnel USB, jamais 127.0.0.1 : réécrit en 10.0.2.2 par les plugins Firebase, test-env\usb-isolation.ps1)."
}
# Aucun identifiant externe hérité : clés retirées, identifiants Google par défaut masqués (dossier gcloud vide).
foreach ($name in 'ANTHROPIC_API_KEY','OPENAI_API_KEY','GEMINI_API_KEY','DEEPSEEK_API_KEY','MISTRAL_API_KEY','GROQ_API_KEY',
                  'FEEXPAY_TOKEN','FEEXPAY_WEBHOOK_SECRET','FEEXPAY_SHOP_ID','GOOGLE_APPLICATION_CREDENTIALS','FIREBASE_TOKEN',
                  'ORANGE_SMS_CLIENT_ID','ORANGE_SMS_CLIENT_SECRET','DELIVERY_SMS_ENABLED') {
  Remove-Item "Env:$name" -ErrorAction SilentlyContinue
}
$emptyGcloud = Join-Path $root 'test-env\runtime\gcloud-empty'
New-Item -ItemType Directory -Force $emptyGcloud | Out-Null
$env:CLOUDSDK_CONFIG = $emptyGcloud
$TestPackage = 'com.azexpress.app.test'
$target = Join-Path $root 'android\app\src\debug\google-services.json'
$apk = Join-Path $root 'build\app\outputs\flutter-apk\app-debug.apk'
if (Test-Path $target) { throw "Déjà présent : $target (build précédent interrompu ? vérifiez puis supprimez-le)." }

# Valeurs de production à ne jamais retrouver dans l'APK (clés Maps lues dans les sources, rien de codé ici).
$prodMapsKeys = @()
$prodMapsKeys += Select-String -Path 'lib\constants\app_constants.dart' -Pattern 'AIza[0-9A-Za-z_-]{20,}' | ForEach-Object { $_.Matches[0].Value }
$localProps = Join-Path $root 'android\local.properties'
if (Test-Path $localProps) {
  $prodMapsKeys += Select-String -Path $localProps -Pattern '^MAPS_API_KEY=(.+)$' | ForEach-Object { $_.Matches[0].Groups[1].Value.Trim() }
}
$prodMapsKeys = @($prodMapsKeys | Where-Object { $_ } | Select-Object -Unique)
if ($TestMapsKey -and ($prodMapsKeys -contains $TestMapsKey)) { throw 'La clé Maps fournie est la clé de production : refusé.' }

try {
  node test-env\make-demo-google-services.js $target
  if ($LASTEXITCODE -ne 0) { throw 'Configuration factice non générée.' }
  node test-env\verify-emulator-isolation.js --android --strict-env
  if ($LASTEXITCODE -ne 0) { throw 'Isolation non validée : build annulé.' }

  # Le paquet est imposé par -P (explicite). Une variable ORG_GRADLE_PROJECT_* n'était pas transmise de façon
  # fiable par Flutter : Gradle compilait alors com.azexpress.app et le plugin Google Services échouait.
  flutter build apk --debug `
    --dart-define=USE_FIREBASE_EMULATORS=true "--dart-define=EMULATOR_HOST=$EmulatorHost" "--dart-define=TEST_MAPS_API_KEY=$TestMapsKey" `
    --android-project-arg=azTestSuffix=.test "--android-project-arg=azTestMapsKey=$TestMapsKey"
  if ($LASTEXITCODE -ne 0) { throw 'flutter build a échoué.' }

  # applicationId RÉEL de l'APK produit (aapt2 du SDK) : exactement com.azexpress.app.test.
  $sdkLine = Select-String -Path $localProps -Pattern '^sdk\.dir=(.+)$' | ForEach-Object { $_.Matches[0].Groups[1].Value.Trim() }
  $sdk = ($sdkLine -replace '\\\\', '\') -replace '\\:', ':'
  $aapt = Get-ChildItem (Join-Path $sdk 'build-tools') -Recurse -Filter aapt2.exe | Sort-Object FullName -Descending | Select-Object -First 1
  if (-not $aapt) { Remove-Item $apk -Force; throw 'aapt2 introuvable : applicationId non vérifiable, APK supprimé.' }
  $badging = & $aapt.FullName dump badging $apk | Select-String -Pattern "^package: name='([^']+)'"
  $appId = $badging.Matches[0].Groups[1].Value
  if ($appId -ne $TestPackage) { Remove-Item $apk -Force; throw "applicationId inattendu : $appId (APK supprimé)." }
  Write-Host "applicationId vérifié : $appId" -ForegroundColor Green

  # Contrôle de l'APK : aucun identifiant Firebase de production, aucune clé Maps de production.
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $zip = [IO.Compression.ZipFile]::OpenRead($apk)
  $forbidden = @($prodMapsKeys) + @('697217052961', 'c645fe608310b5f6ea4e60', 'f7b1b0d0f2e67372ea4e60', '01c30533de15cda1ea4e60', 'az-express-clean')
  $hits = @()
  try {
    foreach ($entry in $zip.Entries) {
      if ($entry.FullName -notmatch '(\.dex$|^resources\.arsc$|kernel_blob\.bin$|^AndroidManifest\.xml$|\.json$|\.so$)') { continue }
      $ms = New-Object IO.MemoryStream
      $s = $entry.Open(); $s.CopyTo($ms); $s.Dispose()
      $bytes = $ms.ToArray()
      $latin = [Text.Encoding]::GetEncoding('iso-8859-1').GetString($bytes)
      $utf16 = [Text.Encoding]::Unicode.GetString($bytes)
      foreach ($f in $forbidden) {
        if ($latin.Contains($f) -or $utf16.Contains($f)) {
          $label = if ($prodMapsKeys -contains $f) { 'clé Google Maps de production' } else { "identifiant $f" }
          $hits += "$($entry.FullName) : $label"
        }
      }
      if ($latin -match 'az-express-b0469(?!\.web\.app)' -or $utf16 -match 'az-express-b0469(?!\.web\.app)') { $hits += "$($entry.FullName) : az-express-b0469" }
    }
  } finally { $zip.Dispose() }
  if ($hits.Count -gt 0) {
    # Mis en quarantaine (jamais installable sous ce nom) pour analyse.
    Move-Item $apk ($apk -replace '\.apk$', '.REJECTED.apk') -Force
    throw ("APK rejeté (renommé .REJECTED.apk) : référence de production détectée :`n  " + ($hits -join "`n  "))
  }
  Write-Host "APK de test ($TestPackage, émulateurs $EmulatorHost) : $apk" -ForegroundColor Green
}
finally {
  if (Test-Path $target) { Remove-Item $target -Force }
}
