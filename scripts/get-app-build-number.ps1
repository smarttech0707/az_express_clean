# Affiche APP_BUILD_NUMBER deduit de pubspec.yaml ("version: x.y.z+N"). Source unique pour run.ps1 et test-env\*.ps1.
# Memes regles que scripts/build_mobile.py (resolve_build_number) : entier strictement positif, au plus 2100000000
# (limite du versionCode Google Play). Absent, nul, negatif ou invalide : message sur stderr et code de sortie 1,
# car un build a 0 ne serait jamais invite a se mettre a jour (MinVersionService).
param(
  [string]$PubspecPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'pubspec.yaml')
)

$max = 2100000000
if (-not (Test-Path $PubspecPath)) {
  [Console]::Error.WriteLine("pubspec.yaml introuvable : $PubspecPath")
  exit 1
}
$match = Select-String -Path $PubspecPath -Pattern '^version:\s*\S+\+(\d+)\s*$' | Select-Object -First 1
$number = 0L
if (-not $match -or -not [long]::TryParse($match.Matches[0].Groups[1].Value, [ref]$number) -or $number -lt 1 -or $number -gt $max) {
  [Console]::Error.WriteLine("APP_BUILD_NUMBER invalide : pubspec.yaml doit contenir 'version: x.y.z+N' avec N entier entre 1 et $max.")
  exit 1
}
Write-Output $number
exit 0
