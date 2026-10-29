"""Audit local du dossier Hosting final. Ne publie rien, n'altère pas le build."""
import hashlib
import json
import re
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
config = json.loads((ROOT / 'firebase.json').read_text(encoding='utf-8'))
public = (ROOT / config['hosting']['public']).resolve()
assert public == ROOT / 'build/web', 'Dossier Hosting inattendu'
assert config['hosting']['ignore'] == ['firebase.json', '**/.*', '**/node_modules/**'], 'Adapter le filtre inventaire aux nouvelles exclusions Hosting'
release = json.loads((public / 'distribution/latest.json').read_text(encoding='utf-8'))
assert release['published'] is True
assert (release['versionName'], release['versionCode'], release['packageId']) == (
    '1.0.9', 10, 'com.azexpress.app')
assert release['downloadUrl'] == 'https://az-express-b0469.web.app/downloads/az-express-latest.apk'

def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest().upper()

for path in [ROOT / 'build/app/outputs/flutter-apk/app-release.apk',
             ROOT / 'web/downloads/az-express-latest.apk',
             public / 'downloads/az-express-latest.apk']:
    assert path.stat().st_size == release['fileSizeBytes'], f'Taille incorrecte : {path}'
    assert sha(path) == release['fileSha256'], f'Hash incorrect : {path}'

for source in (ROOT / 'web').rglob('*'):
    if source.is_file() and source.relative_to(ROOT / 'web').parts[0] in ('downloads', 'distribution', 'telecharger'):
        target = public / source.relative_to(ROOT / 'web')
        assert target.is_file() and sha(source) == sha(target), f'Copie absente ou différente : {target}'

for name in ['index.html', 'flutter_bootstrap.js', 'main.dart.js', 'assets/assets/logo.png']:
    assert (public / name).is_file(), f'Fichier Flutter absent : {name}'
router = (ROOT / 'lib/web/web_router.dart').read_text(encoding='utf-8')
for route in ['/confidentialite', '/delete-account', '/conditions']:
    assert f"'{route}'" in router
assert {'source': '**', 'destination': '/index.html'} in config['hosting']['rewrites']

forbidden_name = re.compile(r'(^|/)(\.env(?:\..*)?|key\.properties|local\.properties|[^/]*service.?account[^/]*|[^/]*\.(?:jks|keystore|pem|p12|aab)|node_modules|\.git)(/|$)', re.I)
secret = re.compile(rb'-----BEGIN (?:RSA |EC |OPENSSH |ENCRYPTED )?PRIVATE KEY-----|"type"\s*:\s*"service_account"|(?:AKIA|ASIA)[A-Z0-9]{16}|ghp_[A-Za-z0-9]{36}|sk_live_[A-Za-z0-9]{20,}')
rows = []
for path in sorted(public.rglob('*')):
    if not path.is_file():
        continue
    relative = path.relative_to(public).as_posix()
    assert not forbidden_name.search(relative), f'Fichier interdit : {relative}'
    content = path.read_bytes()
    assert not secret.search(content), f'Secret potentiel : {relative}'
    if path.suffix == '.apk':
        with zipfile.ZipFile(path) as apk:
            for entry in apk.infolist():
                assert not forbidden_name.search(entry.filename), f'Fichier interdit dans APK : {entry.filename}'
                assert not secret.search(apk.read(entry)), f'Secret potentiel dans APK : {entry.filename}'
    # Scan all files, but list only files Firebase will actually publish.
    if not any(part.startswith('.') or part == 'node_modules' for part in path.relative_to(public).parts) and relative != 'firebase.json':
        rows.append((relative, len(content), hashlib.sha256(content).hexdigest().upper()))

report = ROOT / 'docs/DISTRIBUTION_HOSTING_FILES.md'
report.write_text('# Fichiers prêts pour Firebase Hosting\n\n'
                  'Racine : `build/web`. Inventaire local après exclusions Firebase (notamment `.last_build_id`), aucun déploiement effectué.\n\n'
                  'Les clés publiques de configuration Firebase/Maps sont attendues ; '
                  'aucun fichier de secrets ou motif de clé privée détecté par cet audit.\n\n'
                  '| Fichier | Octets | SHA-256 |\n|---|---:|---|\n' +
                  ''.join(f'| `{p}` | {size} | `{digest}` |\n' for p, size, digest in rows), encoding='utf-8')
print(f'PASS : {len(rows)} fichiers, {sum(row[1] for row in rows)} octets ; intégrité APK, manifeste, copies, routes légales et recherche de secrets.')
print(f'Inventaire : {report}')
