'use strict';
// M1.2 — VRAI SDK Flutter (web, firebase_auth 6.5.2 / cloud_functions 6.3.2 / cloud_firestore 6.5.0, versions de pubspec.lock)
// contre les émulateurs locaux. La sonde (flutter_probe/) tourne dans Chrome headless ; chaque phase est un NOUVEAU
// processus Chrome sur le même profil temporaire (donc un vrai redémarrage avec stockage persistant).
// Limite : Flutter web uniquement (le SDK JS, pas les SDK natifs Android/iOS, dont le stockage de session diffère).
// Lancement : node scripts/m1_feasibility/run-m1-local.js --suite flutter
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const http = require('node:http');
const path = require('node:path');
const { spawn, spawnSync } = require('node:child_process');
const H = require('./m1_1_helpers');

const REPO = path.resolve(__dirname, '..', '..');
const PROBE = path.join(__dirname, 'flutter_probe');
const PORT = 29610;
const PROXY_PORT = 29611;
const PHASE_TIMEOUT_MS = Number(process.env.M1_PHASE_TIMEOUT_MS || 90000);
const ORIGIN = `http://127.0.0.1:${PORT}`;
const FB_FILES = new Set(['firebase-app.js', 'firebase-auth.js', 'firebase-firestore.js', 'firebase-functions.js']);
const MIME = { '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript', '.json': 'application/json', '.wasm': 'application/wasm',
  '.png': 'image/png', '.otf': 'font/otf', '.ttf': 'font/ttf', '.map': 'application/json' };
const tmpRoot = fs.realpathSync(os.tmpdir());

const S = { reports: {}, waiters: {}, tmp: [], served: [] };
const mkTmp = (prefix) => { const d = fs.mkdtempSync(path.join(tmpRoot, prefix)); S.tmp.push(d); return d; };

function findChrome() {
  const c = [process.env.CHROME_PATH, 'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe',
    'C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe'].filter(Boolean);
  const found = c.find((p) => fs.existsSync(p));
  if (!found) throw new Error('Chrome introuvable (CHROME_PATH)');
  return found;
}

function startServer() {
  return new Promise((resolve, reject) => {
    S.server = http.createServer((req, res) => {
      const url = new URL(req.url, ORIGIN);
      res.on('finish', () => S.served.push(`${res.statusCode} ${url.pathname}`));
      if (url.pathname === '/log') { S.served.push('LOG ' + url.searchParams.get('m')); return res.end('ok'); }
      if (url.pathname === '/config') { res.setHeader('content-type', 'application/json'); return res.end(JSON.stringify(S.config)); }
      if (url.pathname === '/report' && req.method === 'POST') {
        let body = '';
        req.on('data', (d) => { body += d; });
        req.on('end', () => {
          const phase = url.searchParams.get('phase');
          S.reports[phase] = JSON.parse(body);
          res.end('ok');
          if (S.waiters[phase]) S.waiters[phase]();
        });
        return;
      }
      let file;
      if (url.pathname.startsWith('/_fb/') && FB_FILES.has(path.basename(url.pathname))) file = path.join(REPO, 'node_modules', 'firebase', path.basename(url.pathname));
      else {
        const rel = path.normalize(url.pathname === '/' ? 'index.html' : url.pathname.slice(1));
        file = path.join(S.buildDir, rel);
        if (!file.startsWith(S.buildDir + path.sep)) { res.statusCode = 403; return res.end(); }
      }
      fs.readFile(file, (err, data) => {
        if (err) { res.statusCode = 404; return res.end(); }
        res.setHeader('content-type', MIME[path.extname(file)] || 'application/octet-stream');
        // Les bundles npm importent firebase-app.js depuis gstatic : réécrit À LA VOLÉE vers la copie locale (fichiers source intacts).
        if (url.pathname.startsWith('/_fb/')) data = Buffer.from(data.toString('utf8').replaceAll('https://www.gstatic.com/firebasejs/12.15.0/', '/_fb/'));
        res.end(data);
      });
    });
    S.server.on('clientError', (_e, socket) => { try { socket.destroy(); } catch (_) { /* déjà fermé */ } });
    S.server.once('error', reject);
    S.server.listen(PORT, '127.0.0.1', resolve);
  });
}

function startBlockingProxy() {
  return new Promise((resolve, reject) => {
    S.blocked = [];
    S.proxy = http.createServer((req, res) => {
      S.blocked.push(new URL(req.url, 'http://x').host);
      res.statusCode = 403; res.end('bloqué par M1.2');
    });
    S.proxy.on('connect', (req, socket) => { // HTTPS : CONNECT host:443
      S.blocked.push(req.url);
      socket.on('error', () => {}); // Chrome ferme/réinitialise ses connexions refusées : ECONNRESET attendu
      socket.end('HTTP/1.1 403 Forbidden\r\n\r\n');
    });
    S.proxy.on('clientError', (_e, socket) => { try { socket.destroy(); } catch (_) { /* déjà fermé */ } });
    S.proxy.once('error', reject);
    S.proxy.listen(PROXY_PORT, '127.0.0.1', resolve);
  });
}

const killTree = (pid) => spawnSync('taskkill', ['/PID', String(pid), '/T', '/F'], { stdio: 'ignore' });

/** Fermeture PROPRE (Browser.close via DevTools) pour que IndexedDB soit écrit sur disque ; repli : arrêt forcé de NOTRE arbre. */
async function closeChrome(chrome) {
  const exited = new Promise((r) => chrome.once('exit', r));
  try {
    const [port, wsPath] = fs.readFileSync(path.join(S.profile, 'DevToolsActivePort'), 'utf8').trim().split(/\r?\n/);
    const ws = new WebSocket(`ws://127.0.0.1:${port}${wsPath}`);
    await Promise.race([new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej; }), new Promise((_, rej) => setTimeout(() => rej(new Error('devtools')), 5000))]);
    ws.send(JSON.stringify({ id: 1, method: 'Browser.close' }));
  } catch (_) { /* repli ci-dessous */ }
  const done = await Promise.race([exited.then(() => true), new Promise((r) => setTimeout(() => r(false), 10000))]);
  if (!done) killTree(chrome.pid);
  await new Promise((r) => setTimeout(r, 1000));
}

/** Lance Chrome headless (processus neuf, profil persistant) sur la phase et attend le rapport de la sonde. */
async function runPhase(phase) {
  const chrome = spawn(findChrome(), ['--headless=new', '--disable-gpu', '--no-first-run', '--no-default-browser-check',
    '--remote-debugging-port=0', `--proxy-server=http://127.0.0.1:${PROXY_PORT}`, `--user-data-dir=${S.profile}`, `${ORIGIN}/?phase=${phase}`], { stdio: 'ignore' });
  try {
    await new Promise((resolve, reject) => {
      const t = setTimeout(() => reject(new Error(`phase ${phase} : pas de rapport après ${PHASE_TIMEOUT_MS / 1000} s | bloqué: ${JSON.stringify([...new Set(S.blocked)])} | servi (fin): ${JSON.stringify(S.served.slice(-25))}`)), PHASE_TIMEOUT_MS);
      S.waiters[phase] = () => { clearTimeout(t); resolve(); };
    });
  } finally {
    await closeChrome(chrome);
  }
  return S.reports[phase];
}

function show(phase) {
  for (const r of S.reports[phase]) {
    console.log(`[P${phase}] ${r.ok ? 'OK ' : 'KO '} ${r.id}${r.error ? ` | erreur=${r.error}` : ''}${r.detail ? ` | ${r.detail}` : ''}`);
  }
}
const stepOf = (phase, prefix) => S.reports[phase].find((r) => r.id.startsWith(prefix));

test.before(async () => {
  await H.resetEmulators();
  S.pw = { c: H.pw(), newC: H.pw(), s: H.pw(), o: H.pw() };
  const mk = async (email, password) => (await H.auth.createUser({ email, password })).uid;
  const email = 'flutter.client@example.test';
  const uidC = await mk(email, S.pw.c);
  const uidO = await mk('flutter.other@example.test', S.pw.o);
  const uidS = await mk('0708080808@az-seller.ci', S.pw.s);
  S.uidC = uidC; S.email = email;
  await H.fsSeed(`clients/${uidC}`, { name: 'Client Flutter', phone: '0701020304', email, wallet: 0, cashOnDeliveryEnabled: true, fakeOrderCount: 0 });
  await H.fsSeed(`clients/${uidO}`, { name: 'Autre', phone: '0702020202', email: 'flutter.other@example.test', wallet: 0 });
  await H.fsSeed(`sellers/${uidS}`, { name: 'Vendeur Flutter', phone: '0708080808', wallet: 0 });
  S.config = {
    otherClientUid: uidO,
    client: { uid: uidC, phone: '0701020304', email, pw: S.pw.c, newPw: S.pw.newC, newEmail: 'flutter.client.new@example.test' },
    seller: { uid: uidS, phone: '0708080808', pw: S.pw.s },
    other: { uid: uidO, email: 'flutter.other@example.test', pw: S.pw.o },
  };
  S.buildDir = process.env.M1_PROBE_BUILD_DIR;
  if (!S.buildDir) {
    S.buildDir = mkTmp('m1-probe-build-');
    const r = spawnSync('flutter build web --no-web-resources-cdn --output "' + S.buildDir + '"', { cwd: PROBE, shell: true, encoding: 'utf8' });
    assert.equal(r.status, 0, `flutter build web a échoué : ${(r.stdout || '').slice(-600)}`);
  }
  S.buildDir = fs.realpathSync(S.buildDir);
  S.profile = mkTmp('m1-probe-chrome-');
  await startBlockingProxy();
  await startServer();
});

test.after(async () => {
  if (S.server) await new Promise((r) => S.server.close(r));
  if (S.proxy) await new Promise((r) => S.proxy.close(r));
  console.log(`[RÉSEAU] requêtes non locales bloquées par le proxy : ${JSON.stringify([...new Set(S.blocked)])}`);
  for (const d of S.tmp) {
    const base = path.basename(d);
    if (path.dirname(d) === tmpRoot && (base.startsWith('m1-probe-build-') || base.startsWith('m1-probe-chrome-'))) {
      try { fs.rmSync(d, { recursive: true, force: true, maxRetries: 5, retryDelay: 500 }); } catch (e) { console.error(`nettoyage ${base}: ${e.message}`); }
    }
  }
});

test('F1 phase 1 : jeton personnalisé, UID, e-mail, providerData, réauthentification, e-mail, mot de passe, rôle', async () => {
  const rep = await runPhase('1');
  show('1');
  for (const r of rep) assert.ok(r.ok, `${r.id} : ${r.error || ''} ${r.detail || ''}`);
  const prov = stepOf('1', '5');
  assert.match(prov.detail, /providerData=\[password\]/, 'providerData doit contenir password');
  assert.match(prov.detail, /signInProvider=custom/);
  assert.match(prov.detail, /isAnonymous=false/);
  for (const k of ['9a', '9b', '9c', '9d']) assert.match(stepOf('1', k).error, /permission-denied/, k);
  assert.match(stepOf('1', '9e').detail, /whoami=client claimsPrivilege=false/);
});

test('F2 après la phase 1 : mot de passe changé côté serveur, demande de changement d’e-mail non appliquée', async () => {
  const idt = `http://${H.AUTH_HOST}/identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=${H.KEY}`;
  const withNew = await H.post(idt, { email: S.email, password: S.pw.newC, returnSecureToken: true });
  const withOld = await H.post(idt, { email: S.email, password: S.pw.c, returnSecureToken: true });
  assert.equal(withNew.status, 200);
  assert.equal(withOld.status, 400);
  const rec = await H.auth.getUser(S.uidC);
  assert.equal(rec.email, S.email, 'e-mail inchangé tant que le lien n’est pas validé');
  const codes = await (await fetch(`http://${H.AUTH_HOST}/emulator/v1/projects/${H.PROJECT}/oobCodes`)).json();
  assert.ok(codes.oobCodes.some((c) => c.requestType === 'VERIFY_AND_CHANGE_EMAIL'), 'demande VERIFY_AND_CHANGE_EMAIL enregistrée');
});

test('F2b témoin : session par mot de passe, puis redémarrage (profil Chrome distinct pour ne pas se mélanger)', async () => {
  const keep = S.profile;
  S.profile = mkTmp('m1-probe-chrome-');
  await runPhase('4'); show('4');
  assert.ok(S.reports['4'].every((r) => r.ok));
  await runPhase('5'); show('5');
  S.control = S.reports['5'][0];
  S.profile = keep;
  assert.ok(S.control.ok, 'session mot de passe non restaurée : le problème viendrait de l’environnement de test, pas du jeton');
});

test('F3 phase 2 (nouveau processus) : session restaurée, jeton renouvelé, déconnexion', async () => {
  const rep = await runPhase('2');
  show('2');
  for (const r of rep) assert.ok(r.ok, `${r.id} : ${r.error || ''} ${r.detail || ''}`);
});

test('F4 phase 3 (nouveau processus) : déconnexion persistée, vendeur, erreurs, nouveau mot de passe, suppression', async () => {
  const rep = await runPhase('3');
  show('3');
  for (const r of rep) assert.ok(r.ok, `${r.id} : ${r.error || ''} ${r.detail || ''}`);
  assert.match(stepOf('3', '14').detail, /role=seller uidOk=true email=0708080808@az-seller\.ci providerData=\[password\]/);
  assert.match(stepOf('3', '15').error, /invalid-custom-token|auth\//);
  assert.match(stepOf('3', '17').error, /functions\/unauthenticated/);
  assert.match(stepOf('3', '18').error, /functions\/invalid-argument/);
  assert.match(stepOf('3', '20').error, /auth\/(wrong-password|invalid-credential)/);
});

test('F5 suppression du compte : l’utilisateur Auth n’existe plus (Admin SDK) ; le profil Firestore n’est PAS supprimé', async () => {
  await assert.rejects(H.auth.getUser(S.uidC), (e) => e.code === 'auth/user-not-found');
  assert.equal(await H.fsGet(`clients/${S.uidC}`, 'owner'), 200, 'profil orphelin : la suppression de données reste à la charge du flux de suppression de compte');
  const r = await H.callable('clientPhoneLoginM1', { identifier: '0701020304', password: S.pw.newC });
  assert.equal(r.body.result.ok, false, 'plus aucune connexion possible pour le compte supprimé');
});

test('F6 aucune requête vers un service Firebase/Google réel : le proxy n’a refusé aucun hôte d’API Firebase', async () => {
  // Chrome émet seulement son trafic de fond (mises à jour, services Google du navigateur) ; le SDK ne doit atteindre QUE les émulateurs.
  const apiHosts = /(identitytoolkit|securetoken|firestore|cloudfunctions|firebaseinstallations|firebase|cloudfunctions\.net|run\.app)/i;
  const hits = [...new Set(S.blocked)].filter((h) => apiHosts.test(h));
  assert.deepEqual(hits, [], `hôtes d'API Firebase contactés : ${hits.join(', ')}`);
});
