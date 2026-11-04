# Deploiement CONTROLE du pilote Restaurant v2 dans la PREPRODUCTION uniquement (az-express-preprod, n 306761725053).
#
# SIMULATION PAR DEFAUT : sans -Execute, aucune commande firebase/gcloud n'est lancee (verifications locales et affichage du plan).
# Avec -Execute : UNE seule etape par appel (-Stage), confirmation explicite (-ConfirmProject), arret immediat a la premiere erreur.
#
# Etapes (ordre recommande) : preflight, rules, indexes, functions-existing, functions-new, functions-proofs, functions-notify
#   powershell -ExecutionPolicy Bypass -File test-env\deploy-restaurant-v2-preprod.ps1                      (simulation de toutes les etapes)
#   powershell -ExecutionPolicy Bypass -File test-env\deploy-restaurant-v2-preprod.ps1 -Stage rules          (simulation d'une etape)
#   ... -Stage rules -Execute -ConfirmProject az-express-preprod                                            (REEL : seulement apres autorisation)
#
# Protections : projet et numero verifies puis refus de tout autre ; liste blanche de fonctions (jamais "functions" seul, jamais de
# joker) ; aucun --force donc aucune suppression ; aucun "firebase use" (--project explicite a chaque commande) ; code deploye = code
# commite (arbre propre exige en reel) ; journal sans secret dans test-env\runtime (ignore par Git).
param(
  [string]$Project = 'az-express-preprod',
  [string]$ProjectNumber = '306761725053',
  [ValidateSet('all', 'preflight', 'rules', 'indexes', 'functions-existing', 'functions-new', 'functions-proofs', 'functions-notify')]
  [string]$Stage = 'all',
  [string]$ConfirmProject = '',
  [switch]$Execute
)
$ErrorActionPreference = 'Stop'
$ExpectedProject = 'az-express-preprod'
$ExpectedNumber = '306761725053'
$ProductionProjects = @('az-express-b0469', 'az-express-clean')
$ProductionNumber = '697217052961'
$root = Split-Path -Parent $PSScriptRoot

# Liste blanche : fonctions par etape. Toute autre cible est refusee tant que ce script n'est pas modifie explicitement.
$Stages = [ordered]@{
  'functions-existing' = @('acceptOrderCF', 'deliverOrderCF', 'cancelOrderCF', 'dispatchOrderToDriver', 'releaseOrderBeforePickupCF', 'syncDriverOrderLifecycle')
  'functions-new'      = @('quotePartnerOrderCF', 'createPartnerOrderFromQuoteCF', 'partnerOrderActionCF', 'adminOrderDisputeCF', 'adminConfirmDeliveryCF', 'autoExpireOrders')
  'functions-proofs'   = @('prepareOrderProof', 'confirmOrderPickupWithProof', 'confirmOrderDeliveryWithProof')
  'functions-notify'   = @('notifyRestaurantOnOrder', 'notifyClientOnOrderUpdate', 'notifyDriversOnNewOrder')
}
$Whitelist = @($Stages.Values | ForEach-Object { $_ })

$LogDir = Join-Path $root 'test-env\runtime'
$LogFile = Join-Path $LogDir ("deploy-restaurant-v2-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
function Log([string]$m) {
  Write-Host $m
  if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
  Add-Content -Path $LogFile -Value ("{0} {1}" -f (Get-Date -Format 'o'), $m)
}
function Fail([string]$m) { Log "REFUS : $m"; throw $m }

# --- 1. Identite du projet (hors ligne) -------------------------------------------------------------------------------
if ($ProductionProjects -ccontains $Project) { Fail "'$Project' est un projet de production." }
if ($Project -cne $ExpectedProject) { Fail "seul '$ExpectedProject' est autorise (recu '$Project')." }
if ($ProjectNumber -eq $ProductionNumber) { Fail "le numero $ProductionNumber est celui de la production." }
if ($ProjectNumber -cne $ExpectedNumber) { Fail "le numero de projet attendu est $ExpectedNumber (recu '$ProjectNumber')." }
if ($Execute) {
  if ($Stage -eq 'all') { Fail "-Execute exige UNE etape precise (-Stage), jamais 'all'." }
  if ($ConfirmProject -cne $ExpectedProject) { Fail "-Execute exige -ConfirmProject $ExpectedProject." }
}
$mode = if ($Execute) { 'REEL' } else { 'SIMULATION' }
Log "Mode: $mode | projet: $Project ($ProjectNumber) | etape: $Stage"

# --- 2. Verifications locales (toujours hors ligne) -------------------------------------------------------------------
Push-Location $root
try {
  $head = (git rev-parse --short HEAD).Trim()
  $dirty = @(git status --porcelain -- functions firestore.rules firestore.indexes.json firebase.json | Where-Object { $_ -notmatch '\.env' })
  Log "Commit local: $head | fichiers deployables modifies non commites: $($dirty.Count)"
  if ($Execute -and $dirty.Count -gt 0) { Fail "arbre non propre (functions/, firestore.rules, firestore.indexes.json) : committer d'abord." }

  # Variables : noms et valeurs NON sensibles uniquement ; aucun secret n'est lu ni journalise.
  $envFile = Join-Path $root 'functions\.env.az-express-preprod'
  if (-not (Test-Path $envFile)) { Fail "functions\.env.az-express-preprod introuvable (modele: test-env\env\functions.env.az-express-preprod.example)." }
  $envMap = @{}
  foreach ($line in (Get-Content $envFile)) {
    $t = $line.Trim()
    if ($t -eq '' -or $t.StartsWith('#')) { continue }
    $i = $t.IndexOf('=')
    if ($i -gt 0) { $envMap[$t.Substring(0, $i).Trim()] = $t.Substring($i + 1).Trim().Trim('"').Trim("'") }
  }
  $required = [ordered]@{
    'DELIVERY_PROOFS_ENABLED' = 'true'; 'DELIVERY_SMS_ENABLED' = 'false'; 'DELIVERY_SMS_PROVIDER' = 'none'
    'FEEXPAY_SHOP_ID' = 'DISABLED'; 'PARTNER_ORDERS_V2' = 'on'; 'PILOT_MAX_INSTANCES' = '1'
  }
  foreach ($k in $required.Keys) {
    if (-not $envMap.ContainsKey($k) -or $envMap[$k] -cne $required[$k]) { Fail "variable $k absente ou differente de la valeur attendue ($($required[$k]))." }
  }
  if ($envMap.ContainsKey('DELIVERY_PROOF_PEPPER')) { Fail "DELIVERY_PROOF_PEPPER est un SECRET : le retirer du fichier .env (firebase functions:secrets:set)." }
  foreach ($k in @('FEEXPAY_TOKEN', 'FEEXPAY_WEBHOOK_SECRET')) {
    if ($envMap.ContainsKey($k) -and $envMap[$k] -notmatch '^(DISABLED|disabled|none)$') { Fail "$k doit etre absent ou DISABLED." }
  }
  if ($envMap.ContainsKey('PARTNER_ORDERS_V2_MANAGE') -and $envMap['PARTNER_ORDERS_V2_MANAGE'] -ceq 'off') { Fail "PARTNER_ORDERS_V2_MANAGE=off gele la gestion : a retirer pour le pilote." }
  Log ("Variables verifiees (noms): " + (($required.Keys) -join ', '))

  # Regles et index.
  $rules = Get-Content (Join-Path $root 'firestore.rules') -Raw
  if ($rules -notmatch "unchanged\('cashPayment'\)") { Fail "firestore.rules ne contient pas le verrou cashPayment (7E-2-S)." }
  $idx = Get-Content (Join-Path $root 'firestore.indexes.json') -Raw | ConvertFrom-Json
  $need = @($idx.indexes | Where-Object {
      $_.collectionGroup -eq 'orders' -and ($_.fields.fieldPath -join ',') -eq 'amountsVersion,status,partnerAcceptedAtMs' })
  if ($need.Count -lt 1) { Fail "index orders(amountsVersion,status,partnerAcceptedAtMs) absent de firestore.indexes.json." }
  Log "Regles (verrou cashPayment) et index requis presents."

  # Liste blanche : chaque fonction doit etre exportee par index.js et plafonnee a 1 instance dans l'analyse du projet de preproduction.
  $indexJs = Get-Content (Join-Path $root 'functions\index.js') -Raw
  foreach ($n in $Whitelist) {
    if ($indexJs -notmatch ("exports\.{0}\s*=" -f [regex]::Escape($n))) { Fail "fonction '$n' non exportee par functions/index.js." }
  }
  $probe = @'
const m=require(process.argv[1]);const names=process.argv.slice(2);const out={};
for(const n of names){const e=m[n]&&m[n].__endpoint;out[n]=e?{max:e.maxInstances===undefined?null:e.maxInstances,region:e.region}:null;}
process.stdout.write('@@'+JSON.stringify(out));
'@
  $env:GCLOUD_PROJECT = $ExpectedProject
  $env:FIREBASE_CONFIG = '{"projectId":"' + $ExpectedProject + '"}'
  $env:PILOT_MAX_INSTANCES = '1'
  $raw = & node -e $probe (Join-Path $root 'functions\index.js') @($Whitelist) 2>&1 | Out-String
  Remove-Item Env:GCLOUD_PROJECT, Env:FIREBASE_CONFIG, Env:PILOT_MAX_INSTANCES -ErrorAction SilentlyContinue
  $json = ($raw.Substring($raw.LastIndexOf('@@') + 2)) | ConvertFrom-Json
  foreach ($n in $Whitelist) {
    $e = $json.$n
    if ($null -eq $e) { Fail "fonction '$n' introuvable a l'analyse de index.js." }
    if ($e.max -ne 1) { Fail "fonction '$n' : maxInstances = $($e.max) au lieu de 1 pour la preproduction." }
    if (($e.region -join ',') -cne 'europe-west1') { Fail "fonction '$n' : region $($e.region -join ',') au lieu de europe-west1." }
  }
  Log ("Fonctions de la liste blanche ({0}) : exportees, region europe-west1, maxInstances = 1." -f $Whitelist.Count)

  # --- 3. Plan des etapes ---------------------------------------------------------------------------------------------
  function Plan([string]$name) {
    switch ($name) {
      'preflight' { return ,@() }
      'rules' { return ,@('deploy', '--project', $Project, '--only', 'firestore:rules', '--non-interactive') }
      'indexes' { return ,@('deploy', '--project', $Project, '--only', 'firestore:indexes', '--non-interactive') }
      default {
        $targets = ($Stages[$name] | ForEach-Object { "functions:$_" }) -join ','
        return ,@('deploy', '--project', $Project, '--only', $targets, '--non-interactive')
      }
    }
  }
  $order = @('preflight', 'rules', 'indexes', 'functions-existing', 'functions-new', 'functions-proofs', 'functions-notify')
  $selected = if ($Stage -eq 'all') { $order } else { @($Stage) }

  function Invoke-Firebase([string[]]$cliArgs) {
    if ($cliArgs -notcontains '--project') { Fail "commande sans --project explicite." }
    if ($cliArgs[($cliArgs.IndexOf('--project') + 1)] -cne $ExpectedProject) { Fail "commande visant un autre projet." }
    if ($cliArgs -contains '--force') { Fail "--force interdit (aucune suppression automatique)." }
    Log ("> firebase " + ($cliArgs -join ' '))
    & firebase @cliArgs
    if ($LASTEXITCODE -ne 0) { Fail "firebase a retourne le code $LASTEXITCODE : arret immediat." }
  }

  foreach ($s in $selected) {
    Log "--- Etape: $s ---"
    $cmd = Plan $s
    if (-not $Execute) {
      if ($s -eq 'preflight') { Log 'Simulation: verifications locales terminees (aucune commande distante).' }
      else { Log ('Simulation: firebase ' + ($cmd -join ' ')) }
      if ($s -eq 'functions-proofs') { Log 'Simulation: secret DELIVERY_PROOF_PEPPER verifie (metadonnees seulement) avant cette etape.' }
      continue
    }
    # Verifications distantes en lecture seule (reel uniquement) : identite du projet par identifiant ET numero.
    $listRaw = (& firebase projects:list --json 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) { Fail "firebase projects:list a echoue." }
    $list = ($listRaw | ConvertFrom-Json).result
    $found = @($list | Where-Object { $_.projectId -ceq $ExpectedProject })
    if ($found.Count -ne 1) { Fail "le projet '$ExpectedProject' n'apparait pas dans le compte connecte." }
    if ([string]$found[0].projectNumber -cne $ExpectedNumber) { Fail "numero de projet $($found[0].projectNumber) different de $ExpectedNumber." }
    if ($s -eq 'preflight') { Log 'Identite du projet confirmee (identifiant et numero).'; continue }
    if ($s -eq 'functions-proofs') {
      Invoke-Firebase @('functions:secrets:get', 'DELIVERY_PROOF_PEPPER', '--project', $Project)
    }
    Invoke-Firebase $cmd
    Log "Etape $s terminee. Verifier avant de continuer."
  }
  Log "Fin ($mode). Journal: $LogFile"
}
finally {
  Pop-Location
}
