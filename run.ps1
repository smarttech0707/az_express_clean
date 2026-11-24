# Lancer AZ Express avec les variables Firebase
# Usage: .\run.ps1              (debug)
# Usage: .\run.ps1 -release     (release)
# Usage: .\run.ps1 -build apk   (build APK ; apk/appbundle/ipa passent par scripts/build_mobile.py)
# Usage: .\run.ps1 -Device <id> (appareil cible, ex. R9PN9018DDJ ; voir `flutter devices`)
# Usage: .\run.ps1 -DryRun ...  (affiche la commande sans lancer Flutter ni Python)
#
# APP_BUILD_NUMBER (contrôle de version minimale) est déduit de pubspec.yaml ("version: x.y.z+N") : refus si le
# numéro est absent ou nul, ou s'il figure déjà dans .env. Un build à 0 ne serait jamais invité à se mettre à jour.

param(
  [switch]$release,
  [string]$build,
  [switch]$DryRun,
  [string]$Device
)

if (-not (Test-Path ".env")) {
  Write-Error "Fichier .env introuvable. Copiez .env.example vers .env et remplissez les valeurs."
  exit 1
}

# Source unique et validation stricte (entier de 1 a 2100000000) : scripts/get-app-build-number.ps1.
$appBuildNumber = & (Join-Path $PSScriptRoot 'scripts/get-app-build-number.ps1')
if ($LASTEXITCODE -ne 0 -or -not $appBuildNumber) {
  Write-Error "APP_BUILD_NUMBER est obligatoire : numero de build de pubspec.yaml absent, nul ou invalide."
  exit 1
}
if (Select-String -Path ".env" -Pattern 'APP_BUILD_NUMBER' -Quiet) {
  Write-Error "APP_BUILD_NUMBER ne doit pas figurer dans .env : il est deduit de pubspec.yaml."
  exit 1
}

function Invoke-Step([string]$exe, [string[]]$stepArgs) {
  if ($DryRun) {
    Write-Host "DRYRUN: $exe $($stepArgs -join ' ')"
    return
  }
  & $exe @stepArgs
  exit $LASTEXITCODE
}

$mobileTargets = @('apk', 'appbundle', 'ipa')
$buildNumberDefine = "--dart-define=APP_BUILD_NUMBER=$appBuildNumber"

if ($build) {
  if ($mobileTargets -contains $build) {
    # Un appel direct à `flutter build` contournerait le contrôle obligatoire du numéro de build.
    $py = if (Get-Command py -ErrorAction SilentlyContinue) { 'py' } else { 'python' }
    $script = Join-Path $PSScriptRoot 'scripts/build_mobile.py'
    $stepArgs = @($script, $build)
    if ($build -ne 'ipa') { $stepArgs += @('--config', (Resolve-Path ".env").Path) }
    Invoke-Step $py $stepArgs
  } elseif ($build -eq 'web') {
    # Le web n'a pas de numéro de build : il se met à jour au déploiement (build 0 = jamais bloqué).
    Invoke-Step 'flutter' @('build', 'web', '--dart-define-from-file=.env')
  } else {
    Invoke-Step 'flutter' @('build', $build, '--dart-define-from-file=.env', $buildNumberDefine)
  }
} else {
  # -Device <id> : appareil cible (flutter devices), meme contrat que `flutter run -d`.
  $runArgs = @('run')
  if ($Device) { $runArgs += @('-d', $Device) }
  $runArgs += @('--dart-define-from-file=.env', $buildNumberDefine)
  if ($release) { $runArgs += '--release' }
  Invoke-Step 'flutter' $runArgs
}
