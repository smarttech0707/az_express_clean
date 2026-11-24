# M1.2 — Test de Ctrl+C du lanceur run-m1-local.js (Windows). Lance le lanceur dans une console cachée DÉDIÉE, y envoie un vrai
# CTRL_C_EVENT (comme un utilisateur dans un terminal), puis vérifie : arrêt, ports libérés, dossier temporaire supprimé,
# functions/node_modules intact, aucun processus résiduel. N'agit que sur la console et les processus qu'il a lui-même créés.
# Usage : powershell -NoProfile -File scripts\m1_feasibility\ctrlc-test.ps1 [-Mode Startup|Tests] (depuis la racine du dépôt)
param([ValidateSet('Startup', 'Tests')][string]$Mode = 'Tests')
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$tmp = [System.IO.Path]::GetTempPath()
$log = Join-Path $tmp ("m1-ctrlc-" + [guid]::NewGuid().ToString('N') + '.log')   # fichier créé par ce test, supprimé à la fin
$ports = 29199, 29080, 29501, 29400, 29500, 29610, 29611, 29620
$nm = Join-Path $repo 'functions\node_modules'
$nmBefore = (Get-ChildItem $nm -Force | Measure-Object).Count
$listening = { param($p) [bool](Get-NetTCPConnection -State Listen -LocalPort $p -ErrorAction SilentlyContinue) }

if ($ports | Where-Object { & $listening $_ }) { throw 'Des ports M1 sont déjà occupés : test annulé (aucune action).' }
$tempBefore = @(Get-ChildItem $tmp -Directory -Filter 'm1-local-*' -ErrorAction SilentlyContinue | ForEach-Object Name)

# Lanceur dans une NOUVELLE console cachée (UseShellExecute + Hidden), sortie vers $log.
$cmd = "node scripts\m1_feasibility\run-m1-local.js --suite core > `"$log`" 2>&1"
$psi = New-Object System.Diagnostics.ProcessStartInfo 'cmd.exe', "/c $cmd"
$psi.WorkingDirectory = $repo; $psi.UseShellExecute = $true; $psi.WindowStyle = 'Hidden'
$proc = [System.Diagnostics.Process]::Start($psi)
Write-Host "Lanceur démarré (cmd PID $($proc.Id))"

# Attente : fonctions prêtes (Startup = dès Auth prêt, avant les tests ; Tests = tests en cours).
$target = if ($Mode -eq 'Startup') { 29199 } else { 29501 }
$t0 = Get-Date
while (-not (& $listening $target)) { if (((Get-Date) - $t0).TotalSeconds -gt 90) { throw 'émulateurs non prêts après 90 s' }; Start-Sleep -Milliseconds 300 }
if ($Mode -eq 'Tests') { Start-Sleep -Seconds 4 }

# Émetteur : un processus à part s'attache à la console du lanceur et envoie CTRL_C_EVENT à son groupe.
$sender = @'
Add-Type -Namespace M1 -Name K -MemberDefinition '
[DllImport("kernel32.dll")] public static extern bool FreeConsole();
[DllImport("kernel32.dll")] public static extern bool AttachConsole(uint pid);
[DllImport("kernel32.dll")] public static extern bool SetConsoleCtrlHandler(IntPtr h, bool add);
[DllImport("kernel32.dll")] public static extern bool GenerateConsoleCtrlEvent(uint ev, uint grp);'
[M1.K]::FreeConsole() | Out-Null
if (-not [M1.K]::AttachConsole([uint32]$args[0])) { Write-Output 'attach-failed'; exit 3 }
[M1.K]::SetConsoleCtrlHandler([IntPtr]::Zero, $true) | Out-Null
[M1.K]::GenerateConsoleCtrlEvent(0, 0) | Out-Null
Start-Sleep -Milliseconds 500
'@
$senderFile = Join-Path $tmp ("m1-ctrlc-sender-" + [guid]::NewGuid().ToString('N') + '.ps1')
Set-Content -Path $senderFile -Value $sender -Encoding ascii
$sentAt = Get-Date
$sp = Start-Process powershell -ArgumentList '-NoProfile', '-File', $senderFile, $proc.Id -WindowStyle Hidden -PassThru -Wait
Write-Host "CTRL_C envoyé (émetteur code $($sp.ExitCode)) en mode $Mode"
Remove-Item $senderFile -Force

$exited = $proc.WaitForExit(90000)
$elapsed = [math]::Round(((Get-Date) - $sentAt).TotalSeconds, 1)
Start-Sleep -Seconds 3
$busy = @($ports | Where-Object { & $listening $_ })
$tempAfter = @(Get-ChildItem $tmp -Directory -Filter 'm1-local-*' -ErrorAction SilentlyContinue | ForEach-Object Name | Where-Object { $tempBefore -notcontains $_ })
$nmAfter = (Get-ChildItem $nm -Force | Measure-Object).Count
$residual = @(Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match 'm1-local-|run-m1-local' -and $_.ProcessId -ne $PID })
$text = if (Test-Path $log) { Get-Content $log -Raw -Encoding utf8 } else { '' }
$clean = [regex]::Replace($text, '\x1b\[[0-9;]*m', '')

Write-Host "---- RÉSULTAT ($Mode) ----"
Write-Host "Lanceur terminé : $exited (en $elapsed s après Ctrl+C), code de sortie cmd : $($proc.ExitCode)"
Write-Host "Gestionnaire SIGINT exécuté (journal, code 130) : $([bool]($clean -match 'SIGINT') -or $proc.ExitCode -eq 130)"
Write-Host "Ports M1 encore occupés : $(if ($busy) { $busy -join ',' } else { 'aucun' })"
Write-Host "Dossiers temporaires m1-local-* créés par ce test et restants : $(if ($tempAfter) { $tempAfter -join ',' } else { 'aucun' })"
Write-Host "functions\node_modules : $nmBefore entrées avant, $nmAfter après"
Write-Host "Processus résiduels liés au lanceur : $($residual.Count)"
$residual | ForEach-Object { Write-Host "  PID $($_.ProcessId) $($_.Name)" }
$ok = $exited -and -not $busy -and -not $tempAfter -and ($nmBefore -eq $nmAfter) -and ($residual.Count -eq 0)
Write-Host ("VERDICT : " + $(if ($ok) { 'OK' } else { 'ÉCHEC' }))
# Nettoyage : uniquement le journal créé par ce test.
if (Test-Path $log) { Remove-Item $log -Force }
exit $(if ($ok) { 0 } else { 1 })
