# Lancer AZ Express avec les variables Firebase
# Usage: .\run.ps1              (debug)
# Usage: .\run.ps1 -release     (release)
# Usage: .\run.ps1 -build apk   (build APK)

param(
  [switch]$release,
  [string]$build
)

if (-not (Test-Path ".env")) {
  Write-Error "Fichier .env introuvable. Copiez .env.example vers .env et remplissez les valeurs."
  exit 1
}

if ($build) {
  flutter build $build --dart-define-from-file=.env
} elseif ($release) {
  flutter run --dart-define-from-file=.env --release
} else {
  flutter run --dart-define-from-file=.env
}
