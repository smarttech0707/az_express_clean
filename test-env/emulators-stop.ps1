# Arrête l'Emulator Suite lancée par emulators-start.ps1 (arbre de processus complet).
$ErrorActionPreference = 'Stop'
$pidFile = Join-Path $PSScriptRoot '.emulators.pid'
$ports = 4000, 4400, 4500, 5001, 8080, 9099, 9150, 9199

if (Test-Path $pidFile) {
  $id = [int](Get-Content $pidFile)
  # taskkill /T arrête aussi java (Firestore) et les processus node enfants.
  & taskkill /PID $id /T /F 2>$null | Out-Null
  Remove-Item $pidFile -Force
}
Start-Sleep -Seconds 2
$left = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { $ports -contains $_.LocalPort }
foreach ($c in $left) {
  $p = Get-Process -Id $c.OwningProcess -ErrorAction SilentlyContinue
  # Seuls les processus java/node des émulateurs sont concernés.
  if ($p -and ($p.ProcessName -in 'java', 'node')) {
    Write-Host "Arrêt résiduel : $($p.ProcessName) (PID $($p.Id), port $($c.LocalPort))"
    Stop-Process -Id $p.Id -Force
  } elseif ($p) {
    Write-Warning "Port $($c.LocalPort) occupé par $($p.ProcessName) : non touché."
  }
}
Write-Host 'Émulateurs arrêtés.'
