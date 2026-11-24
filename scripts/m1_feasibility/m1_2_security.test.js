'use strict';
// M1.2 — sécurité du prototype, ÉMULATEURS locaux uniquement : tentatives répétées, limitation SIMULÉE, temps de réponse,
// création involontaire d'UID, signatures. Tout comportement du service d'identité réel reste une HYPOTHÈSE [H].
// Lancement : node scripts/m1_feasibility/run-m1-local.js --suite security
const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const H = require('./m1_1_helpers');
const { makeClientPhoneLogin, UNIFORM } = require('./clientPhoneLoginPrototype');

const S = {};
const median = (a) => [...a].sort((x, y) => x - y)[Math.floor(a.length / 2)];
const timed = async (fn) => { const t = process.hrtime.bigint(); const r = await fn(); return { r, ms: Number(process.hrtime.bigint() - t) / 1e6 }; };
const callLogin = (identifier, password) => H.callable('clientPhoneLoginM1', { identifier, password });

/** Proxy local vers l'émulateur Auth : compte les vérifications de mot de passe et SIMULE (hypothèse [H]) la limitation du service réel. */
function startThrottlingProxy(port, maxFailuresPerEmail) {
  const stats = { calls: 0, perEmail: {}, failures: {}, throttled: 0 };
  const server = http.createServer((req, res) => {
    let body = '';
    req.on('data', (d) => { body += d; });
    req.on('end', async () => {
      const email = (() => { try { return JSON.parse(body).email; } catch (_) { return undefined; } })();
      if (req.url.includes('accounts:signInWithPassword')) {
        stats.calls++; stats.perEmail[email] = (stats.perEmail[email] || 0) + 1;
        if ((stats.failures[email] || 0) >= maxFailuresPerEmail) {
          stats.throttled++;
          res.statusCode = 400; res.setHeader('content-type', 'application/json');
          return res.end(JSON.stringify({ error: { code: 400, message: 'TOO_MANY_ATTEMPTS_TRY_LATER' } }));
        }
      }
      const up = await fetch(`http://${H.AUTH_HOST}${req.url}`, { method: req.method, headers: { 'content-type': 'application/json' }, body: req.method === 'POST' ? body : undefined });
      const text = await up.text();
      if (req.url.includes('accounts:signInWithPassword') && up.status !== 200) stats.failures[email] = (stats.failures[email] || 0) + 1;
      res.statusCode = up.status; res.setHeader('content-type', 'application/json'); res.end(text);
    });
  });
  return new Promise((resolve) => server.listen(port, '127.0.0.1', () => resolve({ server, stats })));
}

test.before(async () => {
  await H.resetEmulators();
  S.pw = { c: H.pw(), s: H.pw(), dis: H.pw(), a: H.pw() };
  const mk = async (email, password, extra = {}) => (await H.auth.createUser({ email, password, ...extra })).uid;
  S.uidC = await mk('sec.client@example.test', S.pw.c);
  S.uidS = await mk('0708080808@az-seller.ci', S.pw.s);
  S.uidDis = await mk('sec.disabled@example.test', S.pw.dis, { disabled: true });
  S.uidA = await mk('0505050505@azexpress.app', S.pw.a); // alias historique appartenant à A
  await H.fsSeed(`clients/${S.uidC}`, { name: 'C', phone: '0701020304', email: 'sec.client@example.test', wallet: 0 });
  await H.fsSeed(`sellers/${S.uidS}`, { name: 'S', phone: '0708080808', wallet: 0 });
  await H.fsSeed(`clients/${S.uidDis}`, { name: 'D', phone: '0709090909', email: 'sec.disabled@example.test', wallet: 0 });
  S.usersBefore = (await H.auth.listUsers(1000)).users.length;
});

test('S1 tentatives répétées (émulateur) : 40 échecs consécutifs, toujours uniformes, aucune limitation, le titulaire se connecte ensuite', async () => {
  for (let i = 0; i < 40; i++) {
    const r = await callLogin('0701020304', `Mauvais-${i}-mdp`);
    assert.deepEqual(r.body.result, { ok: false, code: 'invalid-credentials', message: 'Identifiants incorrects' });
  }
  const ok = await callLogin('0701020304', S.pw.c);
  assert.equal(ok.body.result.ok, true, 'AUCUNE limitation dans l’émulateur (comportement réel du service d’identité NON VÉRIFIÉ)');
});

test('S2 amplification et limitation SIMULÉE : 3 vérifications par tentative ; une fois l’adresse limitée, le titulaire est refusé de façon uniforme', async () => {
  const { server, stats } = await startThrottlingProxy(29620, 5);
  try {
    const dir = async (phone) => (phone === '0701020304' ? [{ uid: S.uidC, phone, email: 'sec.client@example.test', role: 'client' }] : []);
    const login = makeClientPhoneLogin({ auth: H.auth, directory: dir, restBase: 'http://127.0.0.1:29620', apiKey: H.KEY });
    const before = stats.calls;
    assert.equal((await login({ identifier: '0701020304', password: 'faux-1' })).ok, false);
    assert.equal(stats.calls - before, 3, '3 appels de vérification par tentative (×3 de pression sur le service)');
    const beforeUnknown = stats.calls;
    await login({ identifier: '0799999999', password: 'faux' });
    assert.equal(stats.calls - beforeUnknown, 3, 'même nombre d’appels pour un numéro inconnu');
    for (let i = 0; i < 6; i++) await login({ identifier: '0701020304', password: `faux-${i}` });
    assert.ok(stats.throttled > 0, 'la limitation simulée s’est déclenchée');
    const owner = await login({ identifier: '0701020304', password: S.pw.c });
    assert.deepEqual(owner, UNIFORM, 'SIMULATION : un tiers qui déclenche la limitation bloque aussi le titulaire (réponse uniforme, sans indication)');
    // Le même blocage toucherait la connexion DIRECTE par e-mail si la limitation réelle est par compte (hypothèse [H]).
    console.log(`[S2] appels=${stats.calls} limités=${stats.throttled} (SIMULATION, hypothèse [H] sur le service réel)`);
  } finally { await new Promise((r) => server.close(r)); }
});

test('S3 temps de réponse AVEC plancher (callable) : succès, mauvais mot de passe, inconnu, désactivé, entrée invalide indiscernables', async () => {
  const classes = {
    succes: () => callLogin('0701020304', S.pw.c),
    mauvaisMdp: () => callLogin('0701020304', 'Mauvais-mdp-1'),
    inconnu: () => callLogin('0799999999', 'Mauvais-mdp-1'),
    desactive: () => callLogin('0709090909', S.pw.dis),
    entreeInvalide: () => callLogin('0'.repeat(500), 'x'),
  };
  const med = {};
  for (const [name, fn] of Object.entries(classes)) {
    const xs = [];
    for (let i = 0; i < 9; i++) xs.push((await timed(fn)).ms);
    med[name] = median(xs);
  }
  console.log(`[S3] médianes ms avec plancher: ${JSON.stringify(Object.fromEntries(Object.entries(med).map(([k, v]) => [k, Math.round(v)])))}`);
  const spread = Math.max(...Object.values(med)) - Math.min(...Object.values(med));
  assert.ok(spread < 40, `écart entre classes ${Math.round(spread)} ms (≥ 40 ms)`);
});

test('S4 temps de réponse SANS plancher (prototype direct) : l’écart que le plancher masque', async () => {
  const dir = async (phone) => (phone === '0701020304' ? [{ uid: S.uidC, phone, email: 'sec.client@example.test', role: 'client' }] : []);
  const login = makeClientPhoneLogin({ auth: H.auth, directory: dir, restBase: `http://${H.AUTH_HOST}`, apiKey: H.KEY });
  const cls = {
    succes: () => login({ identifier: '0701020304', password: S.pw.c }),
    mauvaisMdp: () => login({ identifier: '0701020304', password: 'Mauvais-mdp-1' }),
    inconnu: () => login({ identifier: '0799999999', password: 'x' }),
    entreeInvalide: () => login({}),
  };
  const med = {};
  for (const [name, fn] of Object.entries(cls)) {
    const xs = [];
    for (let i = 0; i < 15; i++) xs.push((await timed(fn)).ms);
    med[name] = median(xs);
  }
  console.log(`[S4] médianes ms SANS plancher: ${JSON.stringify(Object.fromEntries(Object.entries(med).map(([k, v]) => [k, +v.toFixed(1)])))}`);
  assert.ok(med.entreeInvalide < med.mauvaisMdp / 3, 'l’entrée invalide répond bien plus vite : fuite de temps sans plancher');
});

test('S5 création involontaire d’UID : aucune tentative (inconnu, désactivé, alias réutilisé, profil sans compte) ne crée d’utilisateur', async () => {
  const ghost = 'ghostUidSansCompte0001';
  await H.fsSeed(`clients/${ghost}`, { name: 'Fantôme', phone: '0711111111', email: 'ghost@example.test', wallet: 0 });
  // Alias réutilisé : le compte Auth 0505050505@azexpress.app appartient à A, mais un AUTRE profil (uidC2) porte ce numéro.
  const uidC2 = (await H.auth.createUser({ email: 'sec.other@example.test', password: H.pw() })).uid;
  await H.fsSeed(`clients/${uidC2}`, { name: 'Autre', phone: '0505050505', email: 'sec.other@example.test', wallet: 0 });
  for (const [id, pw] of [['0711111111', 'x'], ['0799999999', 'x'], ['0709090909', S.pw.dis], ['0505050505', S.pw.a]]) {
    const r = await callLogin(id, pw);
    assert.equal(r.body.result.ok, false, id);
  }
  const after = (await H.auth.listUsers(1000)).users;
  assert.equal(after.some((u) => u.uid === ghost), false, 'aucun compte créé pour le profil fantôme');
  assert.equal(after.length, S.usersBefore + 1 /* uidC2 créé par ce test */, 'aucun utilisateur supplémentaire');
});

test('S6 le risque brut : createCustomToken sans contrôle d’existence crée un compte à l’échange (c’est ce que le prototype évite par getUser)', async () => {
  const uid = 'uidInexistantDirect001';
  const ex = await H.exchange(await H.auth.createCustomToken(uid));
  assert.equal(ex.status, 200);
  assert.equal((await H.auth.getUser(uid)).uid, uid);
});

test('S7 signatures (limite de l’émulateur) : un jeton NON SIGNÉ forgé est accepté par l’émulateur Firestore — ces tests ne prouvent rien sur la signature réelle', async () => {
  const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
  const now = Math.floor(Date.now() / 1000);
  const forged = `${b64({ alg: 'none', typ: 'JWT' })}.${b64({ iss: `https://securetoken.google.com/${H.PROJECT}`, aud: H.PROJECT, auth_time: now, user_id: S.uidC, sub: S.uidC, iat: now, exp: now + 3600, firebase: { identities: {}, sign_in_provider: 'custom' } })}.`;
  assert.equal(await H.fsGet(`clients/${S.uidC}`, forged), 200, 'l’émulateur ne vérifie pas la signature');
  // En production, ce jeton serait rejeté (signature Google absente). NON VÉRIFIÉ ici : exige un environnement réel.
});
