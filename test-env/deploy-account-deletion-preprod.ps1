# Deploiement CONTROLE du systeme de suppression de compte dans la PREPRODUCTION uniquement (az-express-preprod, n 306761725053).
#
# MISSION 7E-71 : script PREPARE, JAMAIS EXECUTE a ce jour. Ne l'executer qu'apres une autorisation distincte et explicite.
#
# SIMULATION PAR DEFAUT : sans -Execute, aucune commande firebase/gcloud n'est lancee (verifications locales et affichage du plan).
# Avec -Execute : UNE seule etape par appel (-Stage), triple confirmation (-ConfirmProject, -ConfirmStage, -QuotaConfirmedByHuman),
# arret immediat a la premiere erreur.
#
#   powershell -ExecutionPolicy Bypass -File test-env\deploy-account-deletion-preprod.ps1                          (simulation de toutes les etapes)
#   powershell -ExecutionPolicy Bypass -File test-env\deploy-account-deletion-preprod.ps1 -Stage functions-deletion (simulation d'une etape)
#   ... -Stage functions-deletion -Execute -ConfirmProject az-express-preprod -ConfirmStage functions-deletion -QuotaConfirmedByHuman
#
# Protections : identifiant ET numero de projet verifies puis refus de tout autre ; liste blanche de fonctions (jamais "functions" seul,
# jamais de joker, jamais Hosting/Firestore/Storage) ; aucun --force donc aucune suppression ; aucun "firebase use" (--project explicite
# a chaque commande) ; code deploye = code commite (arbre propre exige en reel) ; plafond cpu/maxInstances/concurrence verifie par
# analyse locale de index.js avec GCLOUD_PROJECT=az-express-preprod ; marge de quota Cloud Run verifiee sur lecture reelle de
# functions:list ; aucune creation de operations_control/account_deletion (la configuration reste fermee) ; journal sans secret
# dans test-env\runtime (ignore par Git).
param(
  [string]$Project = 'az-express-preprod',
  [string]$ProjectNumber = '306761725053',
  [ValidateSet('all', 'preflight', 'functions-deletion', 'functions-guards')]
  [string]$Stage = 'all',
  [string]$ConfirmProject = '',
  [string]$ConfirmStage = '',
  [switch]$QuotaConfirmedByHuman,
  [double]$QuotaLimitVcpu = 20,
  [double]$MinMarginVcpu = 1.0,
  [switch]$Execute
)
$ErrorActionPreference = 'Stop'
$ExpectedProject = 'az-express-preprod'
$ExpectedNumber = '306761725053'
$ProductionProjects = @('az-express-b0469', 'az-express-clean')
$ProductionNumber = '697217052961'
$root = Split-Path -Parent $PSScriptRoot

# Liste blanche : fonctions par etape, avec la capacite maximale admise (vCPU) verifiee a l'analyse. Toute autre cible est refusee.
$Stages = [ordered]@{
  'functions-deletion' = [ordered]@{
    'requestAccountDeletionCF'   = 0.5
    'getAccountDeletionStatusCF' = 0.25
    'retryAccountDeletions'      = 0.25
    'manageAccountDeletionCF'    = 0.25
  }
  'functions-guards' = [ordered]@{
    'initiateFeexPayPayment' = 0.25
    'initiateWithdrawal'     = 0.25
    'aiConfirmAction'        = 0.25
    'feexPayWebhook'         = 0.25
  }
}
$Whitelist = @($Stages.Values | ForEach-Object { $_.Keys } | ForEach-Object { $_ })

$LogDir = Join-Path $root 'test-env\runtime'
$LogFile = Join-Path $LogDir ("deploy-account-deletion-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
function Log([string]$m) {
  Write-Host $m
  if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
  Add-Content -Path $LogFile -Value ("{0} {1}" -f (Get-Date -Format 'o'), $m)
}
function Fail([string]$m) { Log "REFUS : $m"; throw $m }

# --- 1. Identite du projet (hors ligne) -------------------------------------------------------------------------------
if ($ProductionProjects -contains $Project -or $Project -match 'b0469' -or $Project -match 'clean') { Fail "'$Project' designe la production." }
if ($Project -cne $ExpectedProject) { Fail "seul '$ExpectedProject' est autorise (recu '$Project')." }
if ($ProjectNumber -eq $ProductionNumber) { Fail "le numero $ProductionNumber est celui de la production." }
if ($ProjectNumber -cne $ExpectedNumber) { Fail "le numero de projet attendu est $ExpectedNumber (recu '$ProjectNumber')." }
foreach ($v in @('GCLOUD_PROJECT', 'GOOGLE_CLOUD_PROJECT', 'FIREBASE_PROJECT')) {
  $cur = [Environment]::GetEnvironmentVariable($v)
  if ($cur -and $cur -cne $ExpectedProject) { Fail "la variable d'environnement $v vise '$cur' : la retirer avant de continuer." }
}
if ($Execute) {
  if ($Stage -eq 'all' -or $Stage -eq 'preflight') { Fail "-Execute exige UNE etape de deploiement precise (-Stage functions-deletion ou functions-guards)." }
  if ($ConfirmProject -cne $ExpectedProject) { Fail "-Execute exige -ConfirmProject $ExpectedProject." }
  if ($ConfirmStage -cne $Stage) { Fail "-Execute exige -ConfirmStage $Stage (confirmation de l'etape ciblee)." }
  if (-not $QuotaConfirmedByHuman) { Fail "-Execute exige -QuotaConfirmedByHuman : la consommation reelle du quota Cloud Run (CpuAllocPerProjectRegion, europe-west1) doit avoir ete relevee par un humain dans la console." }
}
$mode = if ($Execute) { 'REEL' } else { 'SIMULATION' }
Log "Mode: $mode | projet: $Project ($ProjectNumber) | etape: $Stage | marge de quota minimale: $MinMarginVcpu vCPU sur $QuotaLimitVcpu"

# --- 2. Verifications locales (toujours hors ligne) -------------------------------------------------------------------
Push-Location $root
try {
  $head = (git rev-parse --short HEAD).Trim()
  $dirty = @(git status --porcelain -- functions firestore.rules firestore.indexes.json firebase.json | Where-Object { $_ -notmatch '\.env' })
  Log "Commit local: $head | fichiers deployables modifies non commites: $($dirty.Count)"
  if ($dirty.Count -gt 0) {
    if ($Execute) { Fail "arbre non propre (functions/, firestore.rules, firestore.indexes.json, firebase.json) : committer d'abord." }
    Log 'AVERTISSEMENT (simulation): le reel serait refuse tant que ces fichiers ne sont pas commites.'
  }

  # Variables : seules les valeurs NON sensibles sont comparees ; aucun secret n'est lu ni journalise.
  $envFile = Join-Path $root 'functions\.env.az-express-preprod'
  if (-not (Test-Path $envFile)) { Fail "functions\.env.az-express-preprod introuvable (modele: test-env\env\functions.env.az-express-preprod.example)." }
  $envMap = @{}
  foreach ($line in (Get-Content $envFile)) {
    $t = $line.Trim()
    if ($t -eq '' -or $t.StartsWith('#')) { continue }
    $i = $t.IndexOf('=')
    if ($i -gt 0) { $envMap[$t.Substring(0, $i).Trim()] = $t.Substring($i + 1).Trim().Trim('"').Trim("'") }
  }
  $required = [ordered]@{ 'FEEXPAY_SHOP_ID' = 'DISABLED'; 'PILOT_MAX_INSTANCES' = '1' }
  foreach ($k in $required.Keys) {
    if (-not $envMap.ContainsKey($k) -or $envMap[$k] -cne $required[$k]) { Fail "variable $k absente ou differente de la valeur attendue ($($required[$k]))." }
  }
  foreach ($k in @('FEEXPAY_TOKEN', 'FEEXPAY_WEBHOOK_SECRET')) {
    if ($envMap.ContainsKey($k) -and $envMap[$k] -notmatch '^(DISABLED|disabled|none)$') { Fail "$k doit etre absent ou DISABLED." }
  }
  foreach ($k in @('DELIVERY_PROOF_PEPPER', 'ANTHROPIC_API_KEY', 'GEMINI_API_KEY')) {
    if ($envMap.ContainsKey($k)) { Fail "$k est un SECRET : le retirer du fichier .env (firebase functions:secrets:set)." }
  }
  foreach ($k in $envMap.Keys) {
    if ($envMap[$k] -match 'b0469' -or $envMap[$k] -match 'az-express-clean') { Fail "la variable $k reference la production." }
  }
  Log ("Variables verifiees (noms): " + (($required.Keys) -join ', ') + ' ; aucune reference a la production.')

  # Liste blanche : exportee par index.js ET plafonnee a l'analyse du projet de preproduction.
  $indexJs = Get-Content (Join-Path $root 'functions\index.js') -Raw
  foreach ($n in $Whitelist) {
    if ($indexJs -notmatch ("exports\.{0}\s*=" -f [regex]::Escape($n))) { Fail "fonction '$n' non exportee par functions/index.js." }
  }
  $probe = @'
const m=require(process.argv[1]);const names=process.argv.slice(2);const out={};
for(const n of names){const e=m[n]&&m[n].__endpoint;out[n]=e?{max:e.maxInstances===undefined?null:e.maxInstances,cpu:e.cpu===undefined?null:e.cpu,conc:e.concurrency===undefined?null:e.concurrency,region:e.region}:null;}
process.stdout.write('@@'+JSON.stringify(out));
'@
  $env:GCLOUD_PROJECT = $ExpectedProject
  $env:FIREBASE_CONFIG = '{"projectId":"' + $ExpectedProject + '"}'
  try { $raw = & node -e $probe (Join-Path $root 'functions\index.js') @($Whitelist) 2>&1 | Out-String }
  finally { Remove-Item Env:GCLOUD_PROJECT, Env:FIREBASE_CONFIG -ErrorAction SilentlyContinue }
  $json = ($raw.Substring($raw.LastIndexOf('@@') + 2)) | ConvertFrom-Json
  $stageCost = @{}
  foreach ($s in $Stages.Keys) {
    $stageCost[$s] = 0.0
    foreach ($n in $Stages[$s].Keys) {
      $e = $json.$n
      if ($null -eq $e) { Fail "fonction '$n' introuvable a l'analyse de index.js." }
      if ($e.max -ne 1) { Fail "fonction '$n' : maxInstances = $($e.max) au lieu de 1 pour la preproduction (aucun maximum = 100 instances reservees)." }
      if ($null -eq $e.cpu -or [double]$e.cpu -gt [double]$Stages[$s][$n]) { Fail "fonction '$n' : cpu = $($e.cpu) (maximum admis $($Stages[$s][$n]))." }
      if ($e.conc -ne 1) { Fail "fonction '$n' : concurrence = $($e.conc) au lieu de 1 (obligatoire sous 1 vCPU)." }
      if (($e.region -join ',') -cne 'europe-west1') { Fail "fonction '$n' : region $($e.region -join ',') au lieu de europe-west1." }
      $stageCost[$s] += [double]$e.cpu * [double]$e.max
    }
    Log ("Etape {0}: {1} fonction(s) plafonnee(s) a 1 instance / concurrence 1 ; empreinte theorique {2} vCPU." -f $s, $Stages[$s].Count, $stageCost[$s])
  }
  Log 'QUOTA NON CONFIRME par ce script : l usage reel de CpuAllocPerProjectRegion n est pas lisible par API ; releve humain obligatoire en reel.'

  # --- 3. Plan des etapes ---------------------------------------------------------------------------------------------
  function Plan([string]$name) {
    $targets = ($Stages[$name].Keys | ForEach-Object { "functions:$_" }) -join ','
    if ($targets -notmatch '^functions:[A-Za-z0-9_]+(,functions:[A-Za-z0-9_]+)*$') { Fail "cible mal formee : $targets" }
    return ,@('deploy', '--project', $Project, '--only', $targets, '--non-interactive')
  }
  $order = @('preflight', 'functions-deletion', 'functions-guards')
  $selected = if ($Stage -eq 'all') { $order } else { @($Stage) }

  function Invoke-Firebase([string[]]$cliArgs) {
    if ($cliArgs -notcontains '--project') { Fail "commande sans --project explicite." }
    if ($cliArgs[($cliArgs.IndexOf('--project') + 1)] -cne $ExpectedProject) { Fail "commande visant un autre projet." }
    if ($cliArgs -contains '--force') { Fail "--force interdit (aucune suppression automatique)." }
    if ($cliArgs -contains 'use') { Fail "firebase use interdit." }
    if ($cliArgs -contains 'deploy') {
      $only = $cliArgs[($cliArgs.IndexOf('--only') + 1)]
      if ($cliArgs -notcontains '--only' -or $only -notmatch '^functions:') { Fail "deploiement hors fonctions ou sans --only interdit (Hosting, Firestore et Storage exclus)." }
      foreach ($t in ($only -split ',')) { if ($Whitelist -notcontains ($t -replace '^functions:', '')) { Fail "cible '$t' hors liste blanche." } }
    }
    Log ("> firebase " + ($cliArgs -join ' '))
    & firebase @cliArgs
    if ($LASTEXITCODE -ne 0) { Fail "firebase a retourne le code $LASTEXITCODE : arret immediat." }
  }

  foreach ($s in $selected) {
    Log "--- Etape: $s ---"
    if ($s -ne 'preflight') { Log ("Fonctions ciblees: " + (($Stages[$s].Keys) -join ', ')) }
    if (-not $Execute) {
      if ($s -eq 'preflight') { Log 'Simulation: verifications locales terminees (aucune commande distante).' }
      else { Log ('Simulation: firebase ' + ((Plan $s) -join ' ')) }
      continue
    }
    # Lectures distantes (reel uniquement, sans effet) : identite du projet par identifiant ET numero.
    $listRaw = (& firebase projects:list --json 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) { Fail "firebase projects:list a echoue." }
    $found = @((($listRaw | ConvertFrom-Json).result) | Where-Object { $_.projectId -ceq $ExpectedProject })
    if ($found.Count -ne 1) { Fail "le projet '$ExpectedProject' n'apparait pas dans le compte connecte." }
    if ([string]$found[0].projectNumber -cne $ExpectedNumber) { Fail "numero de projet $($found[0].projectNumber) different de $ExpectedNumber." }
    Log 'Identite du projet confirmee (identifiant et numero).'

    # Projection de capacite : somme actuelle (cpu x maxInstances, maximum plateforme 100 si absent) + etape.
    $beforeRaw = (& firebase functions:list --project $Project --json 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) { Fail "firebase functions:list a echoue." }
    $before = @((($beforeRaw | ConvertFrom-Json).result))
    $current = 0.0
    foreach ($f in $before) {
      $c = if ($f.cpu) { [double]$f.cpu } else { 1.0 }
      $m = if ($f.maxInstances) { [double]$f.maxInstances } elseif ($f.maxInstanceCount) { [double]$f.maxInstanceCount } else { 100.0 }
      $current += $c * $m
    }
    $projected = $current + $stageCost[$s]
    Log ("Capacite theorique: actuelle {0} + etape {1} = {2} vCPU (limite {3}, marge minimale exigee {4})." -f $current, $stageCost[$s], $projected, $QuotaLimitVcpu, $MinMarginVcpu)
    if ($projected -gt ($QuotaLimitVcpu - $MinMarginVcpu)) { Fail "marge de quota insuffisante ($projected vCPU projetes sur $QuotaLimitVcpu) : decision humaine requise (liberer de la capacite, demande de quota, ou -MinMarginVcpu explicite)." }
    $already = @($before | Where-Object { $Stages[$s].Keys -contains $_.id })
    if ($already.Count -gt 0) { Log ("ATTENTION: deja deployee(s): " + (($already | ForEach-Object { $_.id }) -join ', ') + ' (nouvelle revision, doublement transitoire de capacite possible).') }

    Invoke-Firebase (Plan $s)

    # Controle apres deploiement (lecture) : les fonctions d'origine ne doivent pas avoir ete touchees.
    $afterRaw = (& firebase functions:list --project $Project --json 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) { Fail "firebase functions:list (apres) a echoue." }
    $after = @((($afterRaw | ConvertFrom-Json).result))
    $expectedIds = @($before | ForEach-Object { $_.id }) + @($Stages[$s].Keys) | Sort-Object -Unique
    $afterIds = @($after | ForEach-Object { $_.id }) | Sort-Object -Unique
    $diff = @(Compare-Object $expectedIds $afterIds)
    if ($diff.Count -gt 0) { Fail ("ensemble de fonctions inattendu apres deploiement: " + (($diff | ForEach-Object { $_.InputObject }) -join ', ')) }
    Log "Etape $s terminee. Verifier les journaux et les scenarios avant de continuer. La configuration operations_control/account_deletion n'a PAS ete creee."
  }
  Log "Fin ($mode). Journal: $LogFile"
}
finally {
  Pop-Location
}
