@echo off
rem Double-cliquer : charge les donnees fictives dans les emulateurs LOCAUX (demo-az-express).
rem Le mot de passe est demande dans cette fenetre (12 caracteres minimum), jamais ecrit dans un fichier.
cd /d "%~dp0.."
echo.
echo Les emulateurs doivent deja tourner. Mot de passe : 12 caracteres minimum, rien ne s'affiche en tapant.
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File test-env\emulators-seed.ps1
echo.
if errorlevel 1 (echo ECHEC : copiez le message ci-dessus.) else (echo TERMINE : vous pouvez fermer cette fenetre.)
echo.
pause
