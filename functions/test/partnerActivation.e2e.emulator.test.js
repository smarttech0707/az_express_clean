'use strict';

// Bout en bout sur émulateurs Auth + Firestore AVEC les vraies règles
// (firestore.rules) : vrais jetons d'identité, vraies écritures REST
// authentifiées, vraies fonctions exportées. Ignoré hors émulateur, donc sans
// effet sur `npm test`. Jamais la production.
//
//   npx firebase emulators:exec --config <config avec auth+firestore+rules> \
//     --project az-partner-e2e --only auth,firestore \
//     "node --test functions/test/partnerActivation.e2e.emulator.test.js"
const test = require('node:test');
const assert = require('node:assert/strict');

const enabled = Boolean(process.env.FIRESTORE_EMULATOR_HOST
  && process.env.FIREBASE_AUTH_EMULATOR_HOST && process.env.AZ_E2E_RULES === '1');
const options = { skip: enabled ? false : 'émulateurs + AZ_E2E_RULES=1 requis' };

let fns; let admin; let db; let auth; let run; let project;

test.before(async () => {
  if (!enabled) return;
  project = process.env.GCLOUD_PROJECT || 'az-partner-e2e';
  process.env.GCLOUD_PROJECT = project;
  fns = require('../index.js'); // initialise l'app Admin (émulateurs)
  admin = require('firebase-admin');
  db = admin.firestore();
  auth = admin.auth();
  const { buildManageAdminPartnerAccount } = require('../adminPartnerAccounts');
  run = buildManageAdminPartnerAccount({
    db, auth, fieldValue: admin.firestore.FieldValue,
    checkRateLimit: async () => {}, logAudit: async () => {}, logSecurityEvent: async () => {},
  });
  await db.collection('admins').doc('root').set({ role: 'super', isActive: true });
});

const asAdmin = (data) => ({
  auth: { uid: 'root', token: { firebase: { sign_in_provider: 'password' } } },
  data,
});
async function signIn(email, password) {
  const response = await fetch(
    `http://${process.env.FIREBASE_AUTH_EMULATOR_HOST}/identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=fake`,
    {
      method: 'POST', headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ email, password, returnSecureToken: true }),
    });
  const body = await response.json();
  assert.equal(response.ok, true, 'connexion');
  return body.idToken;
}
const toField = (value) => (typeof value === 'boolean' ? { booleanValue: value } : typeof value === 'number' ? { integerValue: String(value) } : { stringValue: String(value) });
/// Écriture Firestore REST avec un VRAI jeton : les règles s'appliquent.
async function write(idToken, docPath, fields) {
  const mask = Object.keys(fields).map((k) => `updateMask.fieldPaths=${k}`).join('&');
  const response = await fetch(
    `http://${process.env.FIRESTORE_EMULATOR_HOST}/v1/projects/${project}/databases/(default)/documents/${docPath}?${mask}`,
    {
      method: 'PATCH',
      headers: { authorization: `Bearer ${idToken}`, 'content-type': 'application/json' },
      body: JSON.stringify({ fields: Object.fromEntries(Object.entries(fields).map(([k, v]) => [k, toField(v)])) }),
    });
  return response.status;
}
const requestFor = (decoded, data) => ({ auth: { uid: decoded.uid, token: decoded }, data });
const seller = (n) => ({
  action: 'create', kind: 'seller', email: `07000000${n}@az-seller.ci`,
  profile: { name: `Boutique ${n}`, phone: `07000000${n}`, type: 'boutique', lat: 6.7, lng: -3.5 },
});

test('E2E vendeur : refusé avant activation, autorisé après, jeton périmé non pénalisé', options, async () => {
  const created = await run(asAdmin(seller(31)));
  const email = '0700000031@az-seller.ci';
  const before = await signIn(email, created.tempPassword);
  const decoded = await auth.verifyIdToken(before);
  assert.equal(decoded.partnerMustChangePassword, true);

  // 1. profil vendeur
  assert.equal(await write(before, `sellers/${created.uid}`, { name: 'Pirate' }), 403);
  // 5. écriture sur une commande du vendeur
  await db.collection('orders').doc('order-31').set({
    clientId: 'c1', sellerId: created.uid, sellerType: 'seller', budget: 1000,
    status: 'pending', isPaid: false, paymentMethod: 'cash',
  });
  assert.equal(await write(before, 'orders/order-31', { sellerStatus: 'preparing' }), 403);
  // lecture de son propre profil : permise (écran de première connexion)
  const read = await fetch(
    `http://${process.env.FIRESTORE_EMULATOR_HOST}/v1/projects/${project}/databases/(default)/documents/sellers/${created.uid}`,
    { headers: { authorization: `Bearer ${before}` } });
  assert.equal(read.status, 200);
  // 12. impossible de lever l'obligation : ni le journal serveur, ni un drapeau de profil
  assert.equal(await write(before, `partner_provisioning/${created.uid}`, { mustChangePassword: false }), 403);
  assert.equal(await write(before, `sellers/${created.uid}`, { mustChangePassword: false }), 403);

  // 6. retrait d'argent AVANT activation : refusé, aucun débit, aucune demande
  await db.collection('sellers').doc(created.uid).update({ wallet: 5000 });
  await assert.rejects(fns.initiateWithdrawal.run(requestFor(decoded, {
    amount: 1000, phone: '0700000031', operator: 'mtn', userType: 'seller', userName: 'Boutique',
  })), (e) => e.code === 'failed-precondition');
  assert.equal((await db.collection('sellers').doc(created.uid).get()).data().wallet, 5000);
  assert.equal((await db.collection('withdrawal_requests').where('userId', '==', created.uid).get()).size, 0);
  // 7. gestion d'abonnement AVANT activation : refusée
  await assert.rejects(fns.manageProfessionalSubscription.run(requestFor(decoded, {
    action: 'renew', collection: 'sellers', docId: created.uid,
  })), (e) => e.code === 'failed-precondition');
  assert.equal((await db.collection('sellers').doc(created.uid).get()).data().wallet, 5000);

  // changement obligatoire (vraie fonction exportée)
  await fns.completePartnerFirstPasswordChange.run(requestFor(decoded, { newPassword: 'MonNouveau9' }));

  // 8. après activation : accès selon les permissions normales
  const after = await signIn(email, 'MonNouveau9');
  const decodedAfter = await auth.verifyIdToken(after);
  assert.equal(decodedAfter.partnerMustChangePassword, undefined);
  assert.equal(await write(after, `sellers/${created.uid}`, { name: 'Nom légitime' }), 200);
  assert.equal(await write(after, 'orders/order-31', { sellerStatus: 'preparing' }), 200);
  // restrictions financières toujours actives
  assert.equal(await write(after, `sellers/${created.uid}`, { isActive: false }), 403);
  // les fonctions passent la garde (rejet de validation, sans toucher à l'argent ni au réseau)
  await assert.rejects(fns.initiateWithdrawal.run(requestFor(decodedAfter, {
    amount: 100, phone: '0700000031', operator: 'mtn', userType: 'seller',
  })), (e) => e.code === 'invalid-argument');
  const sub = await fns.manageProfessionalSubscription.run(requestFor(decodedAfter, {
    action: 'renew', collection: 'sellers', docId: created.uid,
  }));
  assert.equal(sub.success, true);

  // jetons anciens : l'ancien jeton (revendication périmée) n'est pas pénalisé, le serveur fait autorité
  assert.equal(await write(before, `sellers/${created.uid}`, { name: 'Ancien jeton' }), 200);
});

test('E2E jeton ANCIEN sans revendication : une réinitialisation admin bloque immédiatement les écritures', options, async () => {
  // compte historique : aucun journal, aucune revendication
  const email = '0700000032@az-seller.ci';
  const user = await auth.createUser({ email, password: 'Historique1A' });
  await db.collection('sellers').doc(user.uid).set({ name: 'Ancien', isActive: true, wallet: 10 });
  const oldToken = await signIn(email, 'Historique1A');
  assert.equal(await write(oldToken, `sellers/${user.uid}`, { name: 'Ancien modifié' }), 200, 'compte historique préservé');

  const reset = await run(asAdmin({ action: 'updatePassword', kind: 'seller', uid: user.uid }));
  assert.ok(reset.tempPassword);
  // le jeton émis AVANT la réinitialisation n'a pas la revendication : le journal serveur l'emporte
  assert.equal(await write(oldToken, `sellers/${user.uid}`, { name: 'Contournement' }), 403);
  const decodedOld = await auth.verifyIdToken(oldToken);
  assert.equal(decodedOld.partnerMustChangePassword, undefined);
  await assert.rejects(fns.initiateWithdrawal.run(requestFor(decodedOld, {
    amount: 1000, phone: '0700000032', operator: 'mtn', userType: 'seller',
  })), (e) => e.code === 'failed-precondition');
});

test('E2E boulangerie et restaurant : profil, menu et restaurant refusés avant activation, autorisés après', options, async () => {
  const bakery = await run(asAdmin({
    action: 'create', kind: 'boulangerie', email: '0700000033@az-boulangerie.ci',
    profile: { name: 'Pain', address: 'Rue', phone: '0700000033', openTime: '06:00', closeTime: '20:00', lat: 6.7, lng: -3.5 },
  }));
  const bakeryToken = await signIn('0700000033@az-boulangerie.ci', bakery.tempPassword);
  assert.equal(await write(bakeryToken, `boulangeries/${bakery.uid}`, { name: 'Pirate' }), 403);
  assert.equal(await write(bakeryToken, `boulangeries/${bakery.uid}/menu_items/i1`, { name: 'Pain', price: '200' }), 403);

  const resto = await run(asAdmin({
    action: 'create', kind: 'restaurant', email: '0700000034@az-restaurant.ci',
    profile: {
      name: 'Resto', ownerName: 'Awa', phone: '0700000034', address: 'Rue 1',
      category: 'Ivoirien', lat: 6.7, lng: -3.5,
    },
  }));
  const restoToken = await signIn('0700000034@az-restaurant.ci', resto.tempPassword);
  assert.equal(await write(restoToken, `restaurants/${resto.restaurantId}`, { isOpen: true }), 403);
  assert.equal(await write(restoToken, `restaurants/${resto.restaurantId}/menu/m1`, { name: 'Plat', price: '1000' }), 403);

  for (const [email, tempPassword, uid] of [
    ['0700000033@az-boulangerie.ci', bakery.tempPassword, bakery.uid],
    ['0700000034@az-restaurant.ci', resto.tempPassword, resto.uid],
  ]) {
    const decoded = await auth.verifyIdToken(await signIn(email, tempPassword));
    await fns.completePartnerFirstPasswordChange.run(requestFor(decoded, { newPassword: 'MonNouveau9' }));
    assert.ok(uid);
  }
  const bakeryAfter = await signIn('0700000033@az-boulangerie.ci', 'MonNouveau9');
  assert.equal(await write(bakeryAfter, `boulangeries/${bakery.uid}`, { name: 'Pain légitime' }), 200);
  assert.equal(await write(bakeryAfter, `boulangeries/${bakery.uid}/menu_items/i1`, { name: 'Pain', price: '200' }), 200);
  const restoAfter = await signIn('0700000034@az-restaurant.ci', 'MonNouveau9');
  assert.equal(await write(restoAfter, `restaurants/${resto.restaurantId}`, { isOpen: true }), 200);
  assert.equal(await write(restoAfter, `restaurants/${resto.restaurantId}/menu/m1`, { name: 'Plat', price: '1000' }), 200);
});

test('E2E client ordinaire et administrateur : comportement inchangé', options, async () => {
  const client = await auth.createUser({ email: 'client35@example.test', password: 'Client1Pass' });
  await db.collection('clients').doc(client.uid).set({ name: 'Client', wallet: 100 });
  const clientToken = await signIn('client35@example.test', 'Client1Pass');
  assert.equal(await write(clientToken, `clients/${client.uid}`, { name: 'Nouveau nom' }), 200);

  const adminUser = await auth.createUser({ email: 'admin36@example.test', password: 'Admin1Pass' });
  await db.collection('admins').doc(adminUser.uid).set({ role: 'super', isActive: true });
  await db.collection('sellers').doc('seller-36').set({ name: 'S', isActive: true, wallet: 1 });
  const adminToken = await signIn('admin36@example.test', 'Admin1Pass');
  assert.equal(await write(adminToken, 'sellers/seller-36', { name: 'Modifié par admin' }), 200);
});

// ═════════════════════════════════════════════════════════════════════════════
// Étape B3 — Marketplace, conversations, Boutique, FeexPay, publication
// ═════════════════════════════════════════════════════════════════════════════
async function remove(idToken, docPath) {
  const response = await fetch(
    `http://${process.env.FIRESTORE_EMULATOR_HOST}/v1/projects/${project}/databases/(default)/documents/${docPath}`,
    { method: 'DELETE', headers: { authorization: `Bearer ${idToken}` } });
  return response.status;
}
const validPayment = { amount: 1000, phone: '0700000041', operator: 'mtn', userType: 'seller' };

test('E2E B3 : vendeur non activé — annonces, conversations, Boutique, recharge et publication refusés ; après activation autorisés', options, async () => {
  const created = await run(asAdmin(seller(41)));
  const email = '0700000041@az-seller.ci';
  const before = await signIn(email, created.tempPassword);
  const decoded = await auth.verifyIdToken(before);
  const uid = created.uid;

  await db.collection('sellers').doc(uid).update({ wallet: 5000 });
  await db.collection('marketplace_products').doc('mp-41').set({
    sellerId: uid, status: 'active', views: 0, favoritesCount: 0, title: 'A',
  });
  await db.collection('marketplace_chats').doc('mp_mp-41_buyer41').set({ sellerId: uid, buyerId: 'buyer41' });
  await db.collection('boutique_products').doc('bp-41').set({ sellerId: uid, name: 'Savon', price: 100 });

  // 1. annonces Marketplace
  assert.equal(await write(before, 'marketplace_products/mp-41', { title: 'Pirate' }), 403);
  assert.equal(await remove(before, 'marketplace_products/mp-41'), 403);
  // 3. conversation, côté vendeur
  assert.equal(await write(before, 'marketplace_chats/mp_mp-41_buyer41/messages/m1', { senderUid: uid, type: 'text', text: 'x' }), 403);
  assert.equal(await write(before, 'marketplace_chats/mp_mp-41_buyer41', { lastMessage: 'x' }), 403);
  // 4. Boutique
  assert.equal(await write(before, 'boutique_products/bp-41', { price: 1 }), 403);
  assert.equal(await remove(before, 'boutique_products/bp-41'), 403);
  // 2. publication / republication : aucune annonce créée
  await assert.rejects(fns.publishMarketplaceProduct.run(requestFor(decoded, { product: { title: 'Pirate' } })),
    (e) => e.code === 'failed-precondition');
  await assert.rejects(fns.republishMarketplaceProduct.run(requestFor(decoded, { productId: 'mp-41' })),
    (e) => e.code === 'failed-precondition');
  assert.equal((await db.collection('marketplace_products').get()).docs
    .filter((d) => d.data().title === 'Pirate').length, 0);
  // 5. recharge FeexPay : refusée avant toute transaction, aucun effet financier
  await assert.rejects(fns.initiateFeexPayPayment.run(requestFor(decoded, validPayment)),
    (e) => e.code === 'failed-precondition');
  assert.equal((await db.collection('wallet_transactions').where('userId', '==', uid).get()).size, 0);
  assert.equal((await db.collection('sellers').doc(uid).get()).data().wallet, 5000);
  assert.equal((await db.collection('rate_limits').get()).docs.some((d) => d.id.includes(uid)), false,
    'refusé avant même la limitation de débit');
  // opération ouverte à tous (compteur de vues) : inchangée
  assert.equal(await write(before, 'marketplace_products/mp-41', { views: 1 }), 200);

  // changement obligatoire
  await fns.completePartnerFirstPasswordChange.run(requestFor(decoded, { newPassword: 'MonNouveau9' }));
  const after = await signIn(email, 'MonNouveau9');
  const decodedAfter = await auth.verifyIdToken(after);

  assert.equal(await write(after, 'marketplace_products/mp-41', { title: 'Légitime' }), 200);
  assert.equal(await write(after, 'marketplace_chats/mp_mp-41_buyer41/messages/m1', { senderUid: uid, type: 'text', text: 'Bonjour' }), 200);
  assert.equal(await write(after, 'boutique_products/bp-41', { price: 120 }), 200);
  // ancien jeton (revendication périmée) : le journal serveur fait autorité, pas de blocage
  assert.equal(await write(before, 'boutique_products/bp-41', { price: 130 }), 200);
  assert.equal(await remove(after, 'boutique_products/bp-41'), 200);
  assert.equal(await remove(after, 'marketplace_products/mp-41'), 200);
  // les fonctions passent la garde (rejets de validation, sans effet ni réseau)
  await assert.rejects(fns.publishMarketplaceProduct.run(requestFor(decodedAfter, { product: {} })),
    (e) => e.code === 'invalid-argument');
  await assert.rejects(fns.initiateFeexPayPayment.run(requestFor(decodedAfter, { ...validPayment, amount: 50 })),
    (e) => e.code === 'invalid-argument');
});

test('E2E B3 : jeton ANCIEN après réinitialisation admin — annonces et recharge refusées immédiatement', options, async () => {
  const email = '0700000042@az-seller.ci';
  const user = await auth.createUser({ email, password: 'Historique1A' });
  await db.collection('sellers').doc(user.uid).set({ name: 'Ancien', isActive: true, wallet: 700 });
  await db.collection('marketplace_products').doc('mp-42').set({
    sellerId: user.uid, status: 'active', views: 0, favoritesCount: 0, title: 'A',
  });
  const oldToken = await signIn(email, 'Historique1A');
  assert.equal(await write(oldToken, 'marketplace_products/mp-42', { title: 'Compte historique' }), 200);

  await run(asAdmin({ action: 'updatePassword', kind: 'seller', uid: user.uid }));
  assert.equal(await write(oldToken, 'marketplace_products/mp-42', { title: 'Contournement' }), 403);
  assert.equal(await remove(oldToken, 'marketplace_products/mp-42'), 403);
  const decodedOld = await auth.verifyIdToken(oldToken);
  assert.equal(decodedOld.partnerMustChangePassword, undefined);
  await assert.rejects(fns.initiateFeexPayPayment.run(requestFor(decodedOld, { ...validPayment, phone: '0700000042' })),
    (e) => e.code === 'failed-precondition');
  await assert.rejects(fns.publishMarketplaceProduct.run(requestFor(decodedOld, { product: { title: 'x' } })),
    (e) => e.code === 'failed-precondition');
  assert.equal((await db.collection('sellers').doc(user.uid).get()).data().wallet, 700);
});

test('E2E B3 : client ordinaire et administrateur — comportement préservé, aucun élargissement', options, async () => {
  const client = await auth.createUser({ email: 'client43@example.test', password: 'Client1Pass' });
  await db.collection('clients').doc(client.uid).set({ name: 'Client', wallet: 100 });
  await db.collection('marketplace_products').doc('mp-43').set({
    sellerId: 'someone', status: 'active', views: 0, favoritesCount: 0, title: 'A',
  });
  await db.collection('marketplace_chats').doc(`mp_mp-43_${client.uid}`).set({ sellerId: 'someone', buyerId: client.uid });
  const clientToken = await signIn('client43@example.test', 'Client1Pass');
  assert.equal(await write(clientToken, `marketplace_chats/mp_mp-43_${client.uid}/messages/m1`, { senderUid: client.uid, type: 'text', text: 'Bonjour' }), 200);
  assert.equal(await write(clientToken, 'marketplace_products/mp-43', { views: 1 }), 200);
  assert.equal(await write(clientToken, 'marketplace_products/mp-43', { title: 'Pas le sien' }), 403);
  const decodedClient = await auth.verifyIdToken(clientToken);
  await assert.rejects(fns.initiateFeexPayPayment.run(requestFor(decodedClient, { amount: 50, phone: '0700000043', operator: 'mtn', userType: 'client' })),
    (e) => e.code === 'invalid-argument');

  const adminUser = await auth.createUser({ email: 'admin44@example.test', password: 'Admin1Pass' });
  await db.collection('admins').doc(adminUser.uid).set({ role: 'super', isActive: true });
  await db.collection('boutique_products').doc('bp-44').set({ sellerId: 'seller-44', name: 'S', price: 1 });
  const adminToken = await signIn('admin44@example.test', 'Admin1Pass');
  assert.equal(await write(adminToken, 'boutique_products/bp-44', { price: 5 }), 200);
  assert.equal(await write(adminToken, 'marketplace_products/mp-43', { title: 'Admin' }), 200);
});
