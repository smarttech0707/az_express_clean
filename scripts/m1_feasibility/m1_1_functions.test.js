'use strict';
// M1.1-B — callable locale (émulateur Functions) qui enrobe le prototype M1, avec annuaire Firestore ÉMULÉ.
// Lancement : node scripts/m1_feasibility/run-m1-local.js (démarre les émulateurs et enchaîne les tests).
const test = require('node:test');
const assert = require('node:assert/strict');
const H = require('./m1_1_helpers');

const S = {};
const callLogin = (data, tok) => H.callable('clientPhoneLoginM1', data, tok);
const UNIFORM_BODY = { ok: false, code: 'invalid-credentials', message: 'Identifiants incorrects' };

test.before(async () => {
  await H.resetEmulators();
  S.pwC = H.pw(); S.pwS = H.pw(); S.pwDis = H.pw();
  const mk = async (email, password, extra = {}) => (await H.auth.createUser({ email, password, ...extra })).uid;
  S.uidC = await mk('client.m1@example.test', S.pwC);
  S.uidS = await mk('0708080808@az-seller.ci', S.pwS);
  S.uidDis = await mk('disabled.m1@example.test', S.pwDis, { disabled: true });
  await H.fsSeed(`clients/${S.uidC}`, { name: 'Client Test', phone: '0701020304', email: 'client.m1@example.test', wallet: 0 });
  await H.fsSeed(`sellers/${S.uidS}`, { name: 'Vendeur Test', phone: '0708080808', wallet: 0 });
  await H.fsSeed(`clients/${S.uidDis}`, { name: 'Désactivé', phone: '0709090909', email: 'disabled.m1@example.test', wallet: 0 });
});

test('B1 client : callable → jeton personnalisé → échange → bon UID, rôle serveur', async () => {
  const r = await callLogin({ identifier: '0701020304', password: S.pwC });
  assert.equal(r.status, 200);
  const res = r.body.result;
  assert.equal(res.ok, true);
  assert.deepEqual(Object.keys(res).sort(), ['customToken', 'ok', 'role']);
  assert.equal(res.role, 'client');
  const ex = await H.exchange(res.customToken);
  assert.equal(ex.status, 200);
  const dec = await H.auth.verifyIdToken(ex.body.idToken);
  assert.equal(dec.uid, S.uidC);
  assert.equal(dec.firebase.sign_in_provider, 'custom');
  S.idC = ex.body.idToken;
});

test('B2 vendeur : même callable, UID et rôle seller', async () => {
  const r = await callLogin({ identifier: '0708080808', password: S.pwS });
  assert.equal(r.status, 200);
  assert.equal(r.body.result.ok, true);
  assert.equal(r.body.result.role, 'seller');
  const ex = await H.exchange(r.body.result.customToken);
  assert.equal((await H.auth.verifyIdToken(ex.body.idToken)).uid, S.uidS);
  S.idS = ex.body.idToken;
});

test('B3 aucune donnée sensible dans les réponses (succès et échecs)', async () => {
  const ok = await callLogin({ identifier: '0701020304', password: S.pwC });
  const bad = await callLogin({ identifier: '0701020304', password: 'Mauvais-mot-de-passe-1' });
  const whoami = await H.callable('m1WhoAmI', {}, S.idC);
  const jwtBody = JSON.stringify(H.decodePart(ok.body.result.customToken, 1));
  for (const blob of [JSON.stringify(ok.body), JSON.stringify(bad.body), JSON.stringify(whoami.body), jwtBody]) {
    for (const secret of ['client.m1@example.test', S.pwC, 'az-seller.ci', 'azexpress.app', S.uidS]) {
      assert.ok(!blob.includes(secret), `fuite : ${secret.slice(0, 6)}…`);
    }
  }
  assert.ok(!('email' in whoami.body.result));
});

test('B4 échecs uniformes : mauvais mot de passe, inconnu, désactivé, vide, types invalides, identifiant trop long', async () => {
  const cases = [
    { identifier: '0701020304', password: 'Mauvais-mot-de-passe-1' },
    { identifier: '0799999999', password: 'Mauvais-mot-de-passe-1' },
    { identifier: '0709090909', password: S.pwDis },
    { identifier: '0701020304', password: '' },
    { identifier: 12345, password: ['x'] },
    { identifier: '0'.repeat(500), password: 'x' },
    {},
  ];
  for (const c of cases) {
    const r = await callLogin(c);
    assert.equal(r.status, 200, JSON.stringify(c).slice(0, 40));
    assert.deepEqual(r.body.result, UNIFORM_BODY);
  }
});

test('B5 erreurs de protocole : corps sans data, data non objet → invalid-argument, sans détail interne', async () => {
  const noData = await H.post(`http://${H.FN_HOST}/${H.PROJECT}/europe-west1/clientPhoneLoginM1`, {});
  assert.equal(noData.status, 400);
  const notObj = await callLogin('texte');
  assert.equal(notObj.status, 400);
  for (const r of [noData, notObj]) {
    assert.equal(r.body.error.status, 'INVALID_ARGUMENT');
    assert.ok(!/stack|at\s.+\(|node_modules|firestore|identitytoolkit/i.test(JSON.stringify(r.body)));
  }
});

test('B6 champs injectés par le client (role, claims, uid) ignorés : aucun privilège dans le jeton', async () => {
  const r = await callLogin({ identifier: '0701020304', password: S.pwC, role: 'admin', uid: S.uidS, claims: { admin: true, role: 'super' } });
  assert.equal(r.body.result.ok, true);
  assert.equal(r.body.result.role, 'client');
  const ex = await H.exchange(r.body.result.customToken);
  const dec = await H.auth.verifyIdToken(ex.body.idToken);
  assert.equal(dec.uid, S.uidC);
  assert.ok(!dec.admin && !dec.role);
});

test('B7 session fournie à la connexion (anonyme ou valide) : ignorée, aucun jeton sans mot de passe correct', async () => {
  const anon = await H.signUpAnonymous();
  assert.equal(anon.status, 200);
  const viaAnon = await callLogin({ identifier: '0701020304', password: 'Mauvais-mot-de-passe-1' }, anon.body.idToken);
  assert.deepEqual(viaAnon.body.result, UNIFORM_BODY);
  const viaValid = await callLogin({ identifier: '0701020304', password: 'Mauvais-mot-de-passe-1' }, S.idC);
  assert.deepEqual(viaValid.body.result, UNIFORM_BODY);
});

test('B8 fonction protégée : non connecté et anonyme rejetés, client et vendeur acceptés avec leur rôle', async () => {
  const none = await H.callable('m1WhoAmI', {});
  assert.equal(none.status, 401);
  assert.equal(none.body.error.status, 'UNAUTHENTICATED');
  const anon = await H.signUpAnonymous();
  const a = await H.callable('m1WhoAmI', {}, anon.body.idToken);
  assert.equal(a.status, 403);
  assert.equal(a.body.error.status, 'PERMISSION_DENIED');
  const c = await H.callable('m1WhoAmI', {}, S.idC);
  assert.deepEqual(c.body.result, { uid: S.uidC, role: 'client' });
  const s = await H.callable('m1WhoAmI', {}, S.idS);
  assert.deepEqual(s.body.result, { uid: S.uidS, role: 'seller' });
});

test('B9 compte Auth sans profil Firestore : session refusée par la fonction protégée', async () => {
  const uid = (await H.auth.createUser({ email: 'orphan.m1@example.test', password: H.pw() })).uid;
  const ex = await H.exchange(await H.auth.createCustomToken(uid));
  const r = await H.callable('m1WhoAmI', {}, ex.body.idToken);
  assert.equal(r.status, 403);
});

test('B10 doublon de numéro entre client et vendeur : échec uniforme', async () => {
  await H.fsSeed(`sellers/${S.uidC}`, { name: 'Doublon', phone: '0701020304', wallet: 0 });
  const r = await callLogin({ identifier: '0701020304', password: S.pwC });
  assert.deepEqual(r.body.result, UNIFORM_BODY);
});

test('B11 revendications stockées copiées dans le jeton (extraClaims) : présentes dans la session', async () => {
  await H.auth.setCustomUserClaims(S.uidS, { partnerMustChangePassword: true });
  const r = await callLogin({ identifier: '0708080808', password: S.pwS });
  const ex = await H.exchange(r.body.result.customToken);
  const dec = await H.auth.verifyIdToken(ex.body.idToken);
  assert.equal(dec.partnerMustChangePassword, true);
  await H.auth.setCustomUserClaims(S.uidS, null);
});
