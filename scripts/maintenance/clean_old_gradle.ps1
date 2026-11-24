<#
  Nettoyage des anciennes versions de Gradle (hors projet, aucun code AZ Express touche).

  A lancer APRES avoir completement ferme VS Code, depuis un PowerShell ouvert via le menu Windows :
    powershell -ExecutionPolicy Bypass -File "D:\az_express_clean\scripts\maintenance\clean_old_gradle.ps1"

  Garanties :
    - liste BLANCHE de chemins exacts (versions 8.4, 8.7, 8.9, 8.10, 9.2.0, 9.8.1 uniquement) ;
    - jamais le dossier .gradle entier ; jamais 8.13, 8.14, 8.14.1, modules-2, jars-9 ;
    - aucun processus n'est arrete par ce script ; il refuse de continuer si VS Code, Java ou Gradle tournent ;
    - confirmation explicite avant toute suppression ; fichiers verrouilles ignores.
  Fichier volontairement en ASCII (compatible Windows PowerShell 5.1).
#>
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$gradleHome = Join-Path $env:USERPROFILE '.gradle'
$cachesRoot = Join-Path $gradleHome 'caches'
$distsRoot  = Join-Path $gradleHome 'wrapper\dists'

# --- Liste blanche : chemins EXACTS, construits a partir de versions autorisees ---
$allowedVersions = @('8.4', '8.7', '8.9', '8.10', '9.2.0', '9.8.1')
$allowedDistNames = @('gradle-8.4-bin', 'gradle-8.7-bin', 'gradle-8.7-all', 'gradle-8.9-bin', 'gradle-8.9-all',
                      'gradle-8.10-bin', 'gradle-9.2.0-bin', 'gradle-9.8.1-bin')
$allowed = @()
foreach ($v in $allowedVersions)    { $allowed += (Join-Path $cachesRoot $v) }
foreach ($n in $allowedDistNames)   { $allowed += (Join-Path $distsRoot $n) }

# --- Elements INTERDITS : double securite, meme si la liste blanche etait modifiee par erreur ---
$forbiddenLeaf = @('8.13', '8.14', '8.14.1', 'modules-2', 'jars-9', 'gradle-8.13-bin', 'gradle-8.13-all',
                   'gradle-8.14-bin', 'gradle-8.14-all', 'gradle-8.14.1-bin', 'gradle-8.14.1-all')

function Free-GB { [math]::Round((Get-PSDrive -Name C).Free / 1GB, 2) }

Write-Host ''
Write-Host '=== Nettoyage des anciennes versions de Gradle ===' -ForegroundColor Cyan

# --- 1. Processus : refuser si quelque chose peut encore verrouiller les fichiers ---
$busy = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '^(Code|Code - Insiders|java|javaw|gradle)$' })
if ($busy.Count -gt 0) {
    Write-Host 'ARRET : ces processus tournent encore. Fermez-les vous-meme (ce script ne les arrete jamais) :' -ForegroundColor Red
    $busy | Sort-Object ProcessName, Id | ForEach-Object { Write-Host ('  - {0} (PID {1})' -f $_.ProcessName, $_.Id) }
    exit 1
}
Write-Host 'OK : VS Code, Java et Gradle ne tournent pas.' -ForegroundColor Green

# --- 2. Validation stricte des cibles ---
$targets = @()
foreach ($path in $allowed) {
    $leaf = Split-Path $path -Leaf
    $parent = Split-Path $path -Parent
    if ($forbiddenLeaf -contains $leaf) { throw "Cible interdite dans la liste : $path" }
    if ($parent -ne $cachesRoot -and $parent -ne $distsRoot) { throw "Parent inattendu : $path" }
    if (-not (Test-Path -LiteralPath $path -PathType Container)) { continue }   # deja supprime
    $item = Get-Item -LiteralPath $path -Force
    if ($item.FullName -ne $path) { throw "Chemin non canonique : $path" }
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Lien symbolique refuse : $path" }
    $bytes = (Get-ChildItem -LiteralPath $path -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
    if (-not $bytes) { $bytes = 0 }
    $targets += [pscustomobject]@{ Path = $path; Bytes = [int64]$bytes }
}

if ($targets.Count -eq 0) {
    Write-Host 'Rien a supprimer : toutes les anciennes versions autorisees sont deja absentes.' -ForegroundColor Green
    exit 0
}

Write-Host ''
Write-Host 'Dossiers qui seront supprimes :' -ForegroundColor Yellow
foreach ($t in $targets) { Write-Host ('  {0,6:N2} Go  {1}' -f ($t.Bytes / 1GB), $t.Path) }
$total = ($targets | Measure-Object Bytes -Sum).Sum
Write-Host ('Espace recuperable estime : {0:N2} Go' -f ($total / 1GB))
Write-Host ('Espace libre sur C avant : {0} Go' -f (Free-GB))
Write-Host ''
Write-Host 'Conserves (jamais touches) : 8.13, 8.14, 8.14.1, modules-2, jars-9, SDK Android, Flutter, projets.'

# --- 3. Confirmation ---
$answer = Read-Host 'Tapez OUI (en majuscules) pour supprimer ces dossiers, autre chose pour annuler'
if ($answer -cne 'OUI') { Write-Host 'Annule. Rien n a ete supprime.'; exit 0 }

# --- 4. Suppression : fichier par fichier puis dossiers vides, uniquement sous une cible validee ---
$ok = @(); $failed = @()
$freeBefore = Free-GB
foreach ($t in $targets) {
    $root = $t.Path
    $lockedFiles = 0
    Get-ChildItem -LiteralPath $root -Recurse -Force -File -ErrorAction SilentlyContinue | ForEach-Object {
        if (-not $_.FullName.StartsWith($root + '\')) { return }              # garde-fou : reste sous la cible
        try { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop } catch { $lockedFiles++ }
    }
    Get-ChildItem -LiteralPath $root -Recurse -Force -Directory -ErrorAction SilentlyContinue |
        Sort-Object { $_.FullName.Length } -Descending | ForEach-Object {
            if (-not $_.FullName.StartsWith($root + '\')) { return }
            try { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop } catch { }   # echoue si non vide : voulu
        }
    try { Remove-Item -LiteralPath $root -Force -ErrorAction Stop } catch { }
    if (Test-Path -LiteralPath $root) { $failed += ('{0}  ({1} fichier(s) verrouille(s))' -f $root, $lockedFiles) }
    else { $ok += $root }
}

# --- 5. Bilan ---
Write-Host ''
Write-Host ('Espace libre sur C avant : {0} Go' -f $freeBefore)
Write-Host ('Espace libre sur C apres : {0} Go' -f (Free-GB))
Write-Host ('Recupere                 : {0:N2} Go' -f ((Free-GB) - $freeBefore))
Write-Host ''
Write-Host ('Suppressions reussies ({0}) :' -f $ok.Count) -ForegroundColor Green
$ok | ForEach-Object { Write-Host "  + $_" }
Write-Host ('Echecs / partiels ({0}) :' -f $failed.Count) -ForegroundColor Yellow
$failed | ForEach-Object { Write-Host "  ! $_" }
