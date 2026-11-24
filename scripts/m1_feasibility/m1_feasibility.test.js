'use strict';
// Tests M1 — ÉMULATEUR Auth local uniquement (127.0.0.1:29199, projet demo-m1-feasibility). Données fictives.
// Lancement : node --test scripts/m1_feasibility/m1_feasibility.test.js (émulateur démarré à part).
const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const path = require('node:path');
const { createRequire } = require('node:module');
const req = createRequire(path.join(__dirname, '..', '..', 'functions', 'package.json'));

const HOST = '127.0.0.1:29199';
const PROJECT = 'demo-m1-feasibility';
delete process.env.GOOGLE_APPLICATION_CREDENTIALS;
process.env.FIREBASE_AUTH_EMULATOR_HOST = HOST;
process.env.GCLOUD_PROJECT = PROJECT;
const admin = req('firebase-admin');
admin.initializeApp({ projectId: PROJECT });
const auth = admin.auth();
const { makeClientPhoneLogin, localPost, UNIFORM } = require('./clientPhoneLoginPrototype');

const BASE = `http://${HOST}`;
const KEY = 'fake-api-key';
const pw = () => `Pw-${crypto.randomBytes(8).toString('hex')}`; // jamais journalisé
const decodePart = (jwt, i) => JSON.parse(Buffer.from(jwt.split('.')[i], 'base64url').toString());

const DIR = [];
const directory = async (phone) => DIR.filter((d) => d.phone === phone);
const login = makeClientPhoneLogin({ auth, directory, restBase: BASE, apiKey: KEY });
const loginWithClaims = makeClientPhoneLogin({ auth, directory, restBase: BASE, apiKey: KEY, extraClaims: true });

const idt = `${BASE}/identitytoolkit.googleapis.com/v1`;
const exchange = (customToken) => localPost(`${idt}/accounts:signInWithCustomToken?key=${KEY}`, { token: customToken, returnSecureToken: true });
const lookup = (idToken) => localPost(`${idt}/accounts:lookup?key=${KEY}`, { idToken });
const refresh = (refreshToken) => localPost(`${BASE}/securetoken.googleapis.com/v1/token?key=${KEY}`, { grant_type: 'refresh_token', refresh_token: refreshToken });
const pwSignIn = (email, password) => localPost(`${idt}/accounts:signInWithPassword?key=${KEY}`, { email, password, returnSecureToken: true });
const exists = (uid) => auth.getUser(uid).then(() => true).catch(() => false);

const S = {};
test.before(async () => {
  // Réinitialisation de l'émulateur local (endpoint d'émulateur, hôte local uniquement) pour rendre le test rejouable.
  await fetch(`${BASE}/emulator/v1/projects/${PROJECT}/accounts`, { method: 'DELETE' });
  S.pwA = pw(); S.pwLegacy = pw(); S.pwSeller = pw(); S.pwDis = pw(); S.pwD1 = pw(); S.pwD2 = pw();
  const mk = async (email, password, extra = {}) => (await auth.createUser({ email, password, ...extra })).uid;
  S.uidA = await mk('real.client@example.test', S.pwA);
  S.uidLegacy = await mk('0505050505@azexpress.app', S.pwLegacy);
  S.uidSeller = await mk('0708080808@az-seller.ci', S.pwSeller);
  S.uidDis = await mk('disabled.client@example.test', S.pwDis, { disabled: true });
  S.uidD1 = await mk('dup1@example.test', S.pwD1);
  S.uidD2 = await mk('dup2@example.test', S.pwD2);
  DIR.push(
    { uid: S.uidA, phone: '0701020304', email: 'real.client@example.test', role: 'client' },
    { uid: S.uidLegacy, phone: '0505050505', email: '0505050505@azexpress.app', role: 'client' },
    { uid: S.uidSeller, phone: '0708080808', role: 'seller' },
    { uid: S.uidDis, phone: '0709090909', email: 'disabled.client@example.test', role: 'client' },
    { uid: S.uidD1, phone: '0710101010', email: 'dup1@example.test', role: 'client' },
    { uid: S.uidD2, phone: '0710101010', email: 'dup2@example.test', role: 'client' },
  );
});

test('A1 succès client (e-mail réel) : jeton personnalisé, aucun e-mail dans la réponse, échange vers le bon UID', async () => {
  const r = await login({ identifier: '0701020304', password: S.pwA });
  assert.equal(r.ok, true);
  assert.deepEqual(Object.keys(r).sort(), ['customToken', 'ok', 'role']);
  assert.ok(!JSON.stringify(r).includes('real.client@example.test'));
  assert.ok(!decodePart(r.customToken, 1).email, "le jeton personnalisé ne contient pas d'e-mail");
  const ex = await exchange(r.customToken);
  assert.equal(ex.status, 200);
  S.idA = ex.body.idToken; S.refA = ex.body.refreshToken;
  const dec = await auth.verifyIdToken(S.idA);
  assert.equal(dec.uid, S.uidA);
  S.decA = dec;
  console.log('[A1] claims ID token:', Object.keys(dec).sort().join(','), '| sign_in_provider =', dec.firebase.sign_in_provider);
});

test('A2 profil de session après jeton personnalisé : e-mail et fournisseur password conservés (accounts:lookup)', async () => {
  const u = (await lookup(S.idA)).body.users[0];
  console.log('[A2] e-mail présent:', !!u.email, '| fournisseurs:', (u.providerUserInfo || []).map((p) => p.providerId).join(','));
  assert.equal(u.localId, S.uidA);
  assert.equal(u.email, 'real.client@example.test');
  assert.ok((u.providerUserInfo || []).some((p) => p.providerId === 'password'));
});

test("A3 règles du dépôt : sign_in_provider d'une session par jeton différent de anonymous", async () => {
  assert.notEqual(S.decA.firebase.sign_in_provider, 'anonymous');
  assert.equal(S.decA.firebase.sign_in_provider, 'custom');
  assert.equal(S.decA.phone_number, undefined);
});

test("B1 persistance : renouvellement par refresh token conserve l'UID", async () => {
  const rf = await refresh(S.refA);
  assert.equal(rf.status, 200);
  assert.equal((await auth.verifyIdToken(rf.body.id_token)).uid, S.uidA);
});

test('B2 session ouverte avant par mot de passe non affectée par un nouvel appel de clientPhoneLogin', async () => {
  const before = await pwSignIn('real.client@example.test', S.pwA);
  assert.equal((await login({ identifier: '0701020304', password: S.pwA })).ok, true);
  assert.equal((await auth.verifyIdToken(before.body.idToken, true)).uid, S.uidA);
  assert.equal((await refresh(before.body.refreshToken)).status, 200);
});

test('B3 révocation : refresh tokens invalidés, checkRevoked refuse, nouveau login possible', async () => {
  const viaPw = await pwSignIn('real.client@example.test', S.pwA);
  const viaCt = await exchange((await login({ identifier: '0701020304', password: S.pwA })).customToken);
  await new Promise((r) => setTimeout(r, 1100));
  await auth.revokeRefreshTokens(S.uidA);
  // LIMITE ÉMULATEUR : le renouvellement n'est PAS refusé après revokeRefreshTokens (comportement réel en production : non vérifié ici).
  console.log('[B3] refresh après révocation (émulateur) — mot de passe:', (await refresh(viaPw.body.refreshToken)).status, '| jeton personnalisé:', (await refresh(viaCt.body.refreshToken)).status);
  assert.notEqual((await lookup(viaCt.body.idToken)).status, 200);
  await assert.rejects(() => auth.verifyIdToken(viaCt.body.idToken, true));
  const noCheck = await auth.verifyIdToken(viaCt.body.idToken, false).then(() => 'accepté').catch(() => 'refusé');
  console.log('[B3] ID token révoqué vérifié SANS checkRevoked :', noCheck);
  await new Promise((r) => setTimeout(r, 1100));
  const again = await login({ identifier: '0701020304', password: S.pwA });
  assert.equal(again.ok, true);
  assert.equal((await exchange(again.customToken)).status, 200);
});

test('C1 revendications : un claim stocké passe-t-il dans la session par jeton personnalisé ?', async () => {
  await auth.setCustomUserClaims(S.uidA, { partnerMustChangePassword: true });
  const noDev = await exchange((await login({ identifier: '0701020304', password: S.pwA })).customToken);
  const withDev = await exchange((await loginWithClaims({ identifier: '0701020304', password: S.pwA })).customToken);
  const a = await auth.verifyIdToken(noDev.body.idToken);
  const b = await auth.verifyIdToken(withDev.body.idToken);
  console.log('[C1] claim stocké sans copie :', a.partnerMustChangePassword, '| avec copie explicite :', b.partnerMustChangePassword);
  assert.equal(b.partnerMustChangePassword, true);
  await auth.setCustomUserClaims(S.uidA, null);
});

test("D1 vendeur (alias @az-seller.ci) : même fonction, rôle renvoyé, pas d'e-mail", async () => {
  const r = await login({ identifier: '0708080808', password: S.pwSeller });
  assert.equal(r.ok, true);
  assert.equal(r.role, 'seller');
  assert.equal((await auth.verifyIdToken((await exchange(r.customToken)).body.idToken)).uid, S.uidSeller);
  assert.ok(!JSON.stringify(r).includes('az-seller.ci'));
});

test('D2 ancien compte (alias @azexpress.app) : connexion réussie', async () => {
  const r = await login({ identifier: '0505050505', password: S.pwLegacy });
  assert.equal(r.ok, true);
  assert.equal((await auth.verifyIdToken((await exchange(r.customToken)).body.idToken)).uid, S.uidLegacy);
});

test("E1 échecs uniformes et identiques (mauvais mot de passe, inconnu, désactivé, doublon, numéro seul)", async () => {
  const cases = [
    ['mauvais mdp', { identifier: '0701020304', password: 'faux-faux-faux' }],
    ['inconnu', { identifier: '0799999999', password: S.pwA }],
    ['désactivé (bon mdp)', { identifier: '0709090909', password: S.pwDis }],
    ['doublon (bon mdp)', { identifier: '0710101010', password: S.pwD1 }],
    ['numéro seul (vide)', { identifier: '0701020304', password: '' }],
    ['numéro seul (absent)', { identifier: '0701020304' }],
  ];
  for (const [label, input] of cases) assert.deepEqual(await login(input), UNIFORM, label);
});

test('E2 mesure de temps (indicative, émulateur, non représentative de la production)', async () => {
  const time = async (input, n = 15) => {
    const t = [];
    for (let i = 0; i < n; i++) { const s = process.hrtime.bigint(); await login(input); t.push(Number(process.hrtime.bigint() - s) / 1e6); }
    t.sort((a, b) => a - b);
    return t[Math.floor(n / 2)];
  };
  const known = await time({ identifier: '0701020304', password: 'faux-faux-faux' });
  const unknown = await time({ identifier: '0799999999', password: 'faux-faux-faux' });
  const legacy = await time({ identifier: '0505050505', password: 'faux-faux-faux' });
  console.log(`[E2] médianes ms — e-mail réel: ${known.toFixed(1)} | inconnu: ${unknown.toFixed(1)} | alias: ${legacy.toFixed(1)}`);
});

test("F1 risque : createCustomToken pour un UID inexistant crée un compte à l'échange", async () => {
  const ghost = 'ghost-uid-' + crypto.randomBytes(4).toString('hex');
  const ct = await auth.createCustomToken(ghost);
  assert.equal(await exists(ghost), false);
  assert.equal((await exchange(ct)).status, 200);
  assert.equal(await exists(ghost), true);
});

test("F2 le jeton personnalisé est non signé dans l'émulateur (alg=none) — propre à l'émulateur", async () => {
  const r = await login({ identifier: '0701020304', password: S.pwA });
  const header = decodePart(r.customToken, 0);
  console.log("[F2] en-tête du jeton personnalisé (émulateur):", JSON.stringify(header));
  assert.equal(header.alg, 'none');
});

test("G1 garde d'exécution : un hôte non local est refusé", async () => {
  await assert.rejects(() => localPost('https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=x', {}), /hôte non local/);
});
