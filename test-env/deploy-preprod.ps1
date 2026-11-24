# Déploiement dans le projet de PRÉPRODUCTION uniquement (az-express-preprod).
# Déploiement CIBLÉ : par défaut le premier groupe de 4 fonctions (parcours de commande). Liste blanche stricte plus bas :
# toute autre cible (autre fonction, "functions" seul, joker) est refusée tant que ce script n'est pas modifié explicitement.
# Garde-fous : refuse tout autre identifiant, refuse la production, lance verify-isolation.js, passe toujours --project.
# NE FAIT RIEN tant que -Execute n'est pas fourni (par défaut : affiche seulement la commande).
#
# Usage :
#   powershell -ExecutionPolicy Bypass -File test-env\deploy-preprod.ps1 -Source C:\...\az_isolated_reliability `
#       -GoogleServices C:\az-test\google-services.test.json [-Execute]
param(
  [Parameter(Mandatory = $true)][string]$Source,
  [Parameter(Mandatory = $true)][string]$GoogleServices,
  [string]$Project = 'az-express-preprod',
  [string]$Only = 'functions:dispatchOrderToDriver,functions:acceptOrderCF,functions:deliverOrderCF,functions:syncDriverOrderLifecycle',
  [switch]$Execute
)
$ErrorActionPreference = 'Stop'
$ProductionIds = @('az-express-b0469', 'az-express-clean')
if ($ProductionIds -contains $Project) { throw "REFUS : '$Project' est un projet de production." }
if ($Project -ne 'az-express-preprod') { throw "REFUS : seul 'az-express-preprod' est autorisé par ce script (reçu '$Project')." }
if (-not (Test-Path $Source)) { throw "Source introuvable : $Source" }
$root = Split-Path -Parent $PSScriptRoot

# Liste blanche : seules ces cibles peuvent être déployées par ce script.
$Allowed = @('firestore:rules', 'firestore:indexes', 'storage', 'functions:dispatchOrderToDriver', 'functions:acceptOrderCF', 'functions:deliverOrderCF', 'functions:syncDriverOrderLifecycle')
foreach ($t in ($Only -split ',')) {
  if ($Allowed -notcontains $t.Trim()) { throw "REFUS : la cible '$t' n'est pas dans la liste blanche du script." }
}

Write-Host "1/3 Contrôle d'isolation..."
node (Join-Path $root 'test-env\verify-isolation.js') --env (Join-Path $Source "functions\.env.$Project") `
  --defines (Join-Path $root 'test-env\dart-defines.test.json') --google-services $GoogleServices
if ($LASTEXITCODE -ne 0) { throw "verify-isolation a échoué (code $LASTEXITCODE) : déploiement interdit." }

Write-Host "2/3 Le projet cible doit exister et être accessible..."
$list = firebase projects:list --json | ConvertFrom-Json
$ids = @($list.result | ForEach-Object { $_.projectId })
if ($ids -notcontains $Project) { throw "Le projet '$Project' n'apparaît pas dans votre compte : il n'est pas créé." }

$cmd = "firebase deploy --project $Project --only $Only"
Write-Host "3/3 Commande : $cmd   (depuis $Source)"
if (-not $Execute) { Write-Host "Simulation : ajoutez -Execute pour lancer le déploiement."; exit 0 }
Push-Location $Source
try { firebase deploy --project $Project --only $Only } finally { Pop-Location }
