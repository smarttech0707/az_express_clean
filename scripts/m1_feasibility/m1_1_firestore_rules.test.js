'use strict';
// M1.1-C — VRAIES règles du dépôt (firestore.rules, non modifiées) évaluées par l'émulateur Firestore, avec des ID tokens
// issus du parcours complet : callable locale → jeton personnalisé → échange (émulateur Auth). Les sessions anonymes et
// la session par mot de passe servent de comparaison. Statuts HTTP REST : 200 = autorisé, 403 = refusé par les règles.
const test = require('node:test');
const assert = require('node:assert/strict');
const H = require('./m1_1_helpers');

const S = {};
const allowed = (status) => assert.equal(status, 200);
const denied = (status) => assert.equal(status, 403);
const sessionFor = async (identifier, password) => {
  const r = await H.callable('clientPhoneLoginM1', { identifier, password });
  assert.equal(r.body.result.ok, true);
  const ex = await H.exchange(r.body.result.customToken);
  assert.equal(ex.status, 200);
  return ex.body.idToken;
};

test.before(async () => {
  await H.resetEmulators();
  S.pwC = H.pw(); S.pwC2 = H.pw(); S.pwS = H.pw();
  const mk = async (email, password) => (await H.auth.createUser({ email, password })).uid;
  S.uidC = await mk('rules.client@example.test', S.pwC);
  S.uidC2 = await mk('rules.client2@example.test', S.pwC2);
  S.uidS = await mk('0708080808@az-seller.ci', S.pwS);
  const client = (n, phone, email) => ({ name: n, phone, email, wallet: 0, cashOnDeliveryEnabled: true, fakeOrderCount: 0 });
  allowed(await H.fsSeed(`clients/${S.uidC}`, client('Client A', '0701020304', 'rules.client@example.test')));
  allowed(await H.fsSeed(`clients/${S.uidC2}`, client('Client B', '0702020202', 'rules.client2@example.test')));
  allowed(await H.fsSeed(`sellers/${S.uidS}`, { name: 'Vendeur', phone: '0708080808', wallet: 0, isActive: true }));
  allowed(await H.fsSeed('orders/o1', { clientId: S.uidC, budget: 1000, status: 'pending' }));
  allowed(await H.fsSeed('orders/o2', { clientId: S.uidC2, budget: 1000, status: 'pending' }));
  allowed(await H.fsSeed('marketplace_products/p1', { sellerId: S.uidS, title: 'Article', status: 'active', views: 0, favoritesCount: 0 }));
  S.tokC = await sessionFor('0701020304', S.pwC);
  S.tokS = await sessionFor('0708080808', S.pwS);
  S.tokAnon = (await H.signUpAnonymous()).body.idToken;
  // Comparaison : session ouverte par mot de passe (parcours actuel de l'application).
  const pwSess = await H.post(`http://${H.AUTH_HOST}/identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=${H.KEY}`,
    { email: 'rules.client@example.test', password: S.pwC, returnSecureToken: true });
  S.tokCPw = pwSess.body.idToken;
});

test('C0 les sessions diffèrent comme attendu : custom / custom / anonymous / password', async () => {
  const p = (t) => H.decodePart(t, 1).firebase.sign_in_provider;
  assert.deepEqual([p(S.tokC), p(S.tokS), p(S.tokAnon), p(S.tokCPw)], ['custom', 'custom', 'anonymous', 'password']);
});

test('C1 client (session personnalisée) : accès autorisés à ses propres données', async () => {
  allowed(await H.fsGet(`clients/${S.uidC}`, S.tokC));
  allowed(await H.fsUpdate(`clients/${S.uidC}`, S.tokC, { name: 'Client A modifié' }));
  allowed(await H.fsGet('orders/o1', S.tokC));
});

test('C2 client : accès refusés aux données d’autrui et aux zones protégées', async () => {
  denied(await H.fsGet(`clients/${S.uidC2}`, S.tokC));
  denied(await H.fsGet('orders/o2', S.tokC));
  denied(await H.fsGet(`sellers/${S.uidS}`, S.tokC));
  denied(await H.fsUpdate(`clients/${S.uidC2}`, S.tokC, { name: 'Piraté' }));
  denied(await H.fsUpdate('marketplace_products/p1', S.tokC, { title: 'Piraté' }));
  denied(await H.fsSet(`ai_conversations/${S.uidC}`, S.tokC, { x: 'y' })); // écriture Cloud-Function-only
});

test('C3 client : aucune élévation de privilèges (wallet, administrateur)', async () => {
  denied(await H.fsUpdate(`clients/${S.uidC}`, S.tokC, { wallet: 999999 }));
  denied(await H.fsUpdate(`clients/${S.uidC}`, S.tokC, { cashOnDeliveryEnabled: false }));
  denied(await H.fsSet(`admins/${S.uidC}`, S.tokC, { role: 'super', isActive: true, permissions: 'x' }));
  denied(await H.fsGet(`admins/${S.uidC2}`, S.tokC));
  denied(await H.fsSet('audit_logs/a1', S.tokC, { x: 'y' }));
});

test('C4 vendeur (session personnalisée) : ses données oui, celles des clients non', async () => {
  allowed(await H.fsGet(`sellers/${S.uidS}`, S.tokS));
  allowed(await H.fsUpdate(`sellers/${S.uidS}`, S.tokS, { name: 'Vendeur modifié' }));
  allowed(await H.fsUpdate('marketplace_products/p1', S.tokS, { title: 'Article modifié' }));
  denied(await H.fsGet(`clients/${S.uidC}`, S.tokS));
  denied(await H.fsGet('orders/o1', S.tokS));
  denied(await H.fsUpdate(`sellers/${S.uidS}`, S.tokS, { wallet: 999999 }));
  denied(await H.fsUpdate(`sellers/${S.uidS}`, S.tokS, { isActive: false }));
  denied(await H.fsSet(`admins/${S.uidS}`, S.tokS, { role: 'super', isActive: true, permissions: 'x' }));
});

test('C5 un client ne peut pas utiliser un rôle vendeur (et inversement) malgré la même nature de session', async () => {
  denied(await H.fsUpdate('marketplace_products/p1', S.tokC, { title: 'x' }));
  denied(await H.fsUpdate(`sellers/${S.uidS}`, S.tokC, { name: 'x' }));
  denied(await H.fsUpdate(`clients/${S.uidC}`, S.tokS, { name: 'x' }));
});

test('C6 anonyme vs personnalisée : isRealUser distingue les deux (driver_requests.create)', async () => {
  const body = (uid) => ({ uid, name: 'Candidat', phone: '0700000000' });
  denied(await H.fsSet('driver_requests/r-anon', S.tokAnon, body(H.decodePart(S.tokAnon, 1).user_id)));
  allowed(await H.fsSet('driver_requests/r-custom', S.tokC, body(S.uidC)));
  allowed(await H.fsSet('driver_requests/r-password', S.tokCPw, body(S.uidC)));
});

test('C7 session anonyme : aucune lecture de profil, de commande ou de produit privé', async () => {
  denied(await H.fsGet(`clients/${S.uidC}`, S.tokAnon));
  denied(await H.fsGet('orders/o1', S.tokAnon));
  denied(await H.fsGet(`sellers/${S.uidS}`, S.tokAnon));
  denied(await H.fsUpdate(`clients/${S.uidC}`, S.tokAnon, { name: 'x' }));
});

test('C8 parité avec la session par mot de passe : mêmes droits sur les mêmes documents', async () => {
  for (const [method, p, data] of [
    ['get', `clients/${S.uidC}`], ['get', `clients/${S.uidC2}`], ['get', 'orders/o1'], ['get', 'orders/o2'],
    ['update', `clients/${S.uidC}`, { wallet: 5 }], ['update', `clients/${S.uidC}`, { name: 'Parité' }],
  ]) {
    const f = method === 'get' ? H.fsGet : H.fsUpdate;
    assert.equal(await f(p, S.tokC, data), await f(p, S.tokCPw, data), `${method} ${p}`);
  }
});

test('C9 revendication partnerMustChangePassword copiée dans la session : l’écriture professionnelle reste bloquée', async () => {
  await H.auth.setCustomUserClaims(S.uidS, { partnerMustChangePassword: true });
  const tok = await sessionFor('0708080808', S.pwS);
  assert.equal(H.decodePart(tok, 1).partnerMustChangePassword, true);
  denied(await H.fsUpdate('marketplace_products/p1', tok, { title: 'Bloqué' }));
  allowed(await H.fsGet(`sellers/${S.uidS}`, tok)); // lecture toujours permise (écran de première connexion)
  await H.auth.setCustomUserClaims(S.uidS, null);
});

test('C10 un jeton personnalisé forgé avec un autre UID donne des droits de cet UID (inhérent à Admin SDK, pas aux règles)', async () => {
  // Documente la nature du risque : toute personne capable d'appeler createCustomToken (compte de service) peut
  // incarner n'importe quel UID. Le contrôle est donc l'accès à la signature (IAM), pas les règles Firestore.
  const forged = await H.auth.createCustomToken(S.uidC2);
  const ex = await H.exchange(forged);
  allowed(await H.fsGet(`clients/${S.uidC2}`, ex.body.idToken));
  denied(await H.fsGet(`clients/${S.uidC}`, ex.body.idToken));
});
