# Autorise les téléphones du réseau local à joindre les émulateurs (Auth 9099, Firestore 8080, Functions 5001,
# Storage 9199). À lancer en ADMINISTRATEUR, seulement sur un réseau privé de confiance : les émulateurs n'ont
# pas de mot de passe (les règles Firestore/Storage s'appliquent, pas l'Auth). L'interface (4000) reste locale.
#
#   powershell -ExecutionPolicy Bypass -File test-env\emulators-firewall.ps1 -Action Add
#   powershell -ExecutionPolicy Bypass -File test-env\emulators-firewall.ps1 -Action Remove
param([ValidateSet('Add', 'Remove', 'Show')][string]$Action = 'Show')
$name = 'AZ Express - emulateurs Firebase (test)'
switch ($Action) {
  'Show' {
    Write-Host "Commandes (administrateur) :"
    Write-Host "  New-NetFirewallRule -DisplayName '$name' -Direction Inbound -Protocol TCP -LocalPort 5001,8080,9099,9199 -Profile Private -RemoteAddress LocalSubnet -Action Allow"
    Write-Host "  Remove-NetFirewallRule -DisplayName '$name'"
  }
  'Add' {
    New-NetFirewallRule -DisplayName $name -Direction Inbound -Protocol TCP -LocalPort 5001, 8080, 9099, 9199 `
      -Profile Private -RemoteAddress LocalSubnet -Action Allow | Out-Null
    Write-Host 'Règle ajoutée (profil Privé, sous-réseau local uniquement).'
  }
  'Remove' {
    Remove-NetFirewallRule -DisplayName $name
    Write-Host 'Règle supprimée.'
  }
}
