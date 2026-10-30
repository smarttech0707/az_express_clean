"""Contrôles du numéro de build iOS, avant et après la compilation.

Objectif : ne jamais payer une compilation qui sera refusée par App Store
Connect pour un numéro de build déjà utilisé (HTTP 409, code -19232/-19241).
Aucun secret n'est lu ni affiché. IOS_BUILD_NUMBER doit être une variable
Codemagic NON secrète : un numéro de build n'est pas un secret, et le masquer
rendrait les journaux inexploitables. Rien ici ne contourne ce masquage.
"""
import argparse
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import zipfile

ROOT = Path(__file__).resolve().parents[1]
BUNDLE_ID = 'com.azexpress.app'
NUMBER = re.compile(r'[1-9][0-9]*')
INFO_PLIST = re.compile(r'Payload/[^/]+\.app/Info\.plist')


class GuardError(Exception):
    """Erreur de contrôle : le message est destiné au journal de la compilation."""


def parse_build_number(value):
    text = (value or '').strip()
    if not text:
        raise GuardError('IOS_BUILD_NUMBER est absent : définissez un entier supérieur '
                         'au dernier build envoyé à App Store Connect.')
    if not NUMBER.fullmatch(text):
        raise GuardError('IOS_BUILD_NUMBER est invalide : un entier strictement positif '
                         'sans zéro initial, espace ni suffixe est requis.')
    return int(text)


def pubspec_version(path):
    """Renvoie (nom, numéro) de la ligne `version: X.Y.Z+N` de pubspec.yaml."""
    match = re.search(r'^version:\s*([0-9][^\s+]*)(?:\+(\d+))?\s*$',
                      Path(path).read_text(encoding='utf-8'), re.M)
    if not match:
        raise GuardError('Ligne `version:` introuvable dans pubspec.yaml.')
    return match.group(1), match.group(2)


def parse_latest(output):
    """Dernier entier seul sur une ligne de la sortie du CLI, sinon None."""
    numbers = [int(line) for line in (output or '').splitlines()
               if re.fullmatch(r'\d+', line.strip())]
    return numbers[-1] if numbers else None


def check_candidate(candidate, latest):
    if latest is not None and candidate <= latest:
        raise GuardError(
            f'Le build {candidate} n\'est pas supérieur au '
            f'dernier build connu d\'App Store Connect : {latest}. '
            f'Apple le refuserait (409). Définissez IOS_BUILD_NUMBER à {latest + 1} '
            'ou plus.')


# Injectées par `integrations: app_store_connect` au démarrage du build : elles
# n'apparaissent pas dans les variables de l'application et c'est normal. Seule
# leur présence (jamais la valeur) est journalisée ; c'est le CLI qui tranche.
CREDENTIALS = ('APP_STORE_CONNECT_ISSUER_ID', 'APP_STORE_CONNECT_KEY_IDENTIFIER',
               'APP_STORE_CONNECT_PRIVATE_KEY')


def credentials_status(environ=os.environ):
    return {name: bool(environ.get(name, '').strip()) for name in CREDENTIALS}


def failure_summary(stderr):
    """Dernières lignes utiles de stderr, sans couleurs ni ligne `usage:` géante."""
    clean = re.sub(r'\x1b\[[0-9;]*m', '', stderr or '')
    lines = [line.strip() for line in clean.splitlines()
             if line.strip() and not line.lstrip().startswith('usage:')]
    return ' | '.join(line[:300] for line in lines[-3:])


def latest_from_app_store(run=subprocess.run, environ=os.environ):
    """Plus haut numéro de build connu d'App Store Connect, toutes versions confondues.

    `get-latest-build-number --all-versions` renvoie le maximum entre les builds
    TestFlight (expirés compris) et ceux rattachés aux versions App Store : un
    sur-ensemble de `get-latest-testflight-build-number`. L'option --all-versions
    exige codemagic-cli-tools >= 0.67.0 ; un outil plus ancien la rejette et la
    compilation est bloquée.

    codemagic-cli-tools (vérifié sur 0.70.2) écrit le numéro seul sur stdout
    (print(str(value))) et ses journaux sur stderr. Toute autre situation
    (identifiants absents, erreur d'API, sortie vide) bloque la compilation.
    """
    apple_id = environ.get('APP_STORE_APPLE_ID', '').strip()
    if not re.fullmatch(r'\d+', apple_id):
        raise GuardError(
            'APP_STORE_APPLE_ID est absent ou invalide : renseignez l\'Apple ID '
            'numérique de l\'application (App Store Connect > Informations sur '
            'l\'app).')
    command = ['app-store-connect', 'get-latest-build-number',
               '--all-versions', '--platform', 'IOS', apple_id]
    try:
        result = run(command, capture_output=True, text=True, timeout=120)
    except FileNotFoundError as error:
        raise GuardError('Outil app-store-connect introuvable sur cette machine.') from error
    except subprocess.TimeoutExpired as error:
        raise GuardError('App Store Connect ne répond pas (délai de 120 s dépassé).') from error
    if result.returncode != 0:
        tail = failure_summary(result.stderr)
        absent = [name for name, present in credentials_status(environ).items()
                  if not present]
        hint = (' Variables absentes de l\'environnement : ' + ', '.join(absent)
                + ' (l\'intégration « AZ Express Codemagic » est-elle attachée ?).'
                if absent else '')
        raise GuardError('Lecture du dernier build App Store Connect impossible '
                         f'(code {result.returncode}) : {tail or "sans détail"}.{hint}')
    latest = parse_latest(result.stdout)
    if latest is None:
        raise GuardError('Réponse vide d\'App Store Connect : dernier build inconnu.')
    return latest


def git_value(*args, run=subprocess.run):
    try:
        result = run(['git', *args], cwd=ROOT, capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired):
        return 'inconnu'
    return result.stdout.strip() or 'inconnu'


def describe_source(environ=os.environ):
    commit = environ.get('CM_COMMIT') or git_value('rev-parse', 'HEAD')
    branch = environ.get('CM_BRANCH') or git_value('rev-parse', '--abbrev-ref', 'HEAD')
    return commit, branch


def preflight(environ=os.environ, run=subprocess.run):
    candidate = parse_build_number(environ.get('IOS_BUILD_NUMBER'))
    name, _ = pubspec_version(ROOT / 'pubspec.yaml')
    commit, branch = describe_source(environ)
    print(f'Version de l\'application : {name}')
    print(f'Build demandé (IOS_BUILD_NUMBER) : {candidate}')
    print(f'Commit compilé : {commit} (branche {branch})')
    for name, present in credentials_status(environ).items():
        print(f'{name} : {"présent" if present else "absent"}')
    latest = latest_from_app_store(run=run, environ=environ)
    check_candidate(candidate, latest)
    print(f'Dernier build App Store Connect : {latest} -> {candidate} est disponible.')
    return 0


def read_ipa(ipa_dir):
    ipas = sorted(Path(ipa_dir).glob('*.ipa'))
    if len(ipas) != 1:
        raise GuardError(f'Un seul IPA est attendu dans {ipa_dir}, {len(ipas)} trouvé(s).')
    with zipfile.ZipFile(ipas[0]) as archive:
        plists = [name for name in archive.namelist() if INFO_PLIST.fullmatch(name)]
        if len(plists) != 1:
            raise GuardError('Info.plist de l\'application introuvable dans l\'IPA.')
        info = plistlib.loads(archive.read(plists[0]))
    return ipas[0].name, info


def verify_ipa(expected_value, ipa_dir, pubspec=None, environ=os.environ):
    expected = parse_build_number(expected_value)
    name, ipa_info = read_ipa(ipa_dir)
    bundle = ipa_info.get('CFBundleIdentifier')
    version = ipa_info.get('CFBundleShortVersionString')
    build = str(ipa_info.get('CFBundleVersion', ''))
    commit, branch = describe_source(environ)
    print(f'IPA : {name}')
    print(f'Application : {bundle}')
    print(f'Version de l\'application : {version}')
    print(f'Build réellement intégré à l\'IPA (CFBundleVersion) : {build}')
    print(f'Build demandé : {expected}')
    print(f'Commit compilé : {commit} (branche {branch})')
    if bundle != BUNDLE_ID:
        raise GuardError(f'Identifiant de l\'application inattendu : {bundle}.')
    if build != str(expected):
        raise GuardError(
            f'Incohérence : l\'IPA contient le build {build} alors que '
            f'IOS_BUILD_NUMBER vaut {expected}. Envoi à Apple interdit.')
    expected_version, _ = pubspec_version(pubspec or ROOT / 'pubspec.yaml')
    if version != expected_version:
        raise GuardError(f'Version de l\'IPA ({version}) différente de pubspec.yaml '
                         f'({expected_version}).')
    print('Contrôle IPA : OK, le numéro de build est celui demandé.')
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    commands.add_parser('preflight', help='avant la compilation')
    verify = commands.add_parser('verify-ipa', help='après la compilation')
    verify.add_argument('--ipa-dir', type=Path, default=ROOT / 'build/ios/ipa')
    args = parser.parse_args(argv)
    try:
        if args.command == 'preflight':
            return preflight()
        return verify_ipa(os.environ.get('IOS_BUILD_NUMBER'), args.ipa_dir)
    except GuardError as error:
        print(f'ERREUR : {error}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
