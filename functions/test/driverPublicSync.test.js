'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { admin: fakeAdmin } = require('./lifecycleFake');
const {
  DRIVER_PUBLIC_FIELDS,
  isValidFieldValue,
  computeDriverPublicPatch,
  buildFirestorePatch,
  syncDriverPublicOnCreate,
  syncDriverPublicOnUpdate,
  syncDriverPublicOnDelete,
} = require('../driverPublicSync');

// Faux `db` minimal avec support de `runTransaction` (SEC-01 / S5.3.3 — la reconciliation lit
// désormais `livreurs` ET `driver_public` dans une transaction avant d'écrire). Distinct de
// `lifecycleFake.fakeDb` (transactionnel lui aussi, mais orienté comptes/retraits) ; réutilise
// en revanche son faux `admin.firestore.FieldValue.delete()` pour cohérence.
//
// AVERTISSEMENT (mission S5.3.3, phase 4) — ce que cette fausse transaction simule et ce
// qu'elle NE simule PAS : elle reproduit fidèlement « lire l'état courant au moment de
// l'exécution, puis écrire » — c'est tout ce dont la correction du RISK A a besoin pour être
// démontrée (voir tests 12-19 ci-dessous : on mute directement le store entre deux appels pour
// représenter « d'autres écritures ont déjà eu lieu », puis on vérifie que l'appel suivant lit
// bien l'état le plus récent). Elle NE simule PAS le mécanisme réel de Cloud Firestore qui
// avorte et rejoue automatiquement une transaction si un document lu a changé AVANT que cette
// transaction ne se valide (contention en cours d'exécution) — cette garantie précise ne peut
// être vérifiée qu'avec l'émulateur Firestore réel ou en production, aucun des deux n'étant
// utilisé ici. Ce point est documenté explicitement dans
// `docs/SEC01_S5_3_3_CONCURRENCY_FIX.md` plutôt que présenté comme prouvé par ces tests.
function fakeDb(seed = {}) {
  const store = new Map(Object.entries(seed).map(([k, v]) => [k, v ? { ...v } : v]));
  let writeCount = 0;
  const path = (name, id) => `${name}/${id}`;
  const readDoc = (p) => ({ exists: store.has(p), data: () => (store.has(p) ? { ...store.get(p) } : undefined) });
  const applySet = (p, data, options) => {
    const current = options?.merge ? { ...(store.get(p) || {}) } : {};
    for (const [k, v] of Object.entries(data)) {
      if (v && v.__delete) delete current[k];
      else current[k] = v;
    }
    store.set(p, current);
    writeCount++;
  };
  const applyDelete = (p) => {
    store.delete(p);
    writeCount++;
  };
  const ref = (name, id) => ({
    __path: path(name, id),
    get: async () => readDoc(path(name, id)),
    set: async (data, options) => applySet(path(name, id), data, options),
    delete: async () => applyDelete(path(name, id)),
  });
  const db = {
    collection: (name) => ({ doc: (id) => ref(name, id) }),
    runTransaction: async (fn) => fn({
      get: async (r) => readDoc(r.__path),
      set: (r, data, options) => applySet(r.__path, data, options),
      delete: (r) => applyDelete(r.__path),
    }),
  };
  return { db, store, writes: () => writeCount };
}

// ── computeDriverPublicPatch (pure, inchangée depuis S5.2/S5.3) ────────────────────────────

test('1-7. synchronise chaque champ whitelisté individuellement', () => {
  const cases = [
    ['name', 'Ancien', 'Nouveau'],
    ['photoUrl', 'https://x/old.jpg', 'https://x/new.jpg'],
    ['isOnline', false, true],
    ['isAvailable', true, false],
    ['isOnDelivery', false, true],
    ['avgRating', 4.0, 4.5],
    ['ratingCount', 3, 4],
  ];
  for (const [field, before, after] of cases) {
    const patch = computeDriverPublicPatch({ before: { [field]: before }, after: { [field]: after } });
    assert.equal(patch.hasChanges, true, field);
    assert.deepEqual(patch.fields, { [field]: after }, field);
    assert.deepEqual(patch.toDelete, [], field);
  }
});

test('8. whitelist stricte : seuls les 7 champs peuvent apparaître dans la sortie', () => {
  assert.deepEqual(DRIVER_PUBLIC_FIELDS, [
    'name', 'photoUrl', 'isOnline', 'isAvailable', 'isOnDelivery', 'avgRating', 'ratingCount',
  ]);
  const realistic = {
    name: 'D', photoUrl: 'https://x/p.jpg', isOnline: true, isAvailable: true,
    isOnDelivery: false, avgRating: 4.2, ratingCount: 7,
    wallet: 5000, phone: '0700000000', fcmToken: 'tok', ownerId: 'fleet-1',
    isSuspended: false, identifiant: 'ID-1', lat: 6.7, lng: -3.4, heading: 1, speed: 1, updatedAt: 1,
  };
  const patch = computeDriverPublicPatch({ before: {}, after: realistic });
  assert.equal(Object.keys(patch.fields).every((k) => DRIVER_PUBLIC_FIELDS.includes(k)), true);
});

test('9. absence de fuite de champs sensibles, même présents dans before ET after', () => {
  const sensitive = {
    wallet: 5000, phone: '0700000000', fcmToken: 'tok', token: 'tok2', ownerId: 'fleet-1',
    ownerName: 'Patron', isSuspended: true, deletionRequested: true, identifiant: 'ID-1',
  };
  const patch = computeDriverPublicPatch({
    before: { name: 'A', ...sensitive },
    after: { name: 'B', ...sensitive },
  });
  for (const key of Object.keys(sensitive)) {
    assert.equal(key in patch.fields, false, key);
    assert.equal(patch.toDelete.includes(key), false, key);
  }
  assert.deepEqual(patch.fields, { name: 'B' });
});

test('10. les champs GPS ne sont jamais lus, écrits ni effacés par ce module', () => {
  const patch = computeDriverPublicPatch({
    before: { lat: 6.7, lng: -3.4, heading: 10, speed: 0, updatedAt: 1 },
    after: {},
  });
  assert.deepEqual(patch.fields, {});
  assert.deepEqual(patch.toDelete, []);
  assert.equal(patch.hasChanges, false);
});

test('10b. buildFirestorePatch ne touche jamais une clé GPS existante (merge implicite)', () => {
  const patch = computeDriverPublicPatch({ before: {}, after: { isOnline: true } });
  const data = buildFirestorePatch(fakeAdmin, patch);
  assert.deepEqual(Object.keys(data), ['isOnline']);
});

test('11. document source invalide ou incomplet : jamais de valeur inventée', () => {
  assert.deepEqual(computeDriverPublicPatch({ before: {}, after: {} }),
    { fields: {}, toDelete: [], skipped: [], hasChanges: false });
  assert.deepEqual(computeDriverPublicPatch({ before: null, after: null }),
    { fields: {}, toDelete: [], skipped: [], hasChanges: false });

  const badTypes = computeDriverPublicPatch({
    before: {},
    after: { name: 42, photoUrl: true, isOnline: 'oui', avgRating: '4', ratingCount: -1 },
  });
  assert.deepEqual(badTypes.fields, {});
  assert.equal(badTypes.skipped.length, 5);
  assert.equal(badTypes.hasChanges, false);
});

test('11b. champ retiré de la source (anonymisation RGPD) : propagé comme suppression', () => {
  const patch = computeDriverPublicPatch({
    before: { name: 'Ancien', photoUrl: 'https://x/p.jpg', isOnline: true },
    after: { isOnline: false },
  });
  assert.deepEqual(patch.fields, { isOnline: false });
  assert.deepEqual(patch.toDelete.sort(), ['name', 'photoUrl']);
  const data = buildFirestorePatch(fakeAdmin, patch);
  assert.equal(data.isOnline, false);
  assert.deepEqual(data.name, fakeAdmin.firestore.FieldValue.delete());
  assert.deepEqual(data.photoUrl, fakeAdmin.firestore.FieldValue.delete());
});

// ── SEC-01 / S5.3.3 — reconciliation par lecture live : CONCURRENCE (Phase 4, points 1-8) ────

test('12. [concurrence] événement ancien exécuté après événement récent : le résultat reflète '
  + "l'état le plus récent de livreurs, jamais la valeur périmée d'un événement en retard "
  + '(RISK A corrigé)', async () => {
  const { db, store } = fakeDb({ 'livreurs/d1': { name: 'D', isOnline: true } });
  // Entre l'événement A (isOnline:true, déjà dépassé) et l'exécution retardée de son trigger,
  // un événement B (isOnline:false) a déjà été écrit sur la source — représenté ici par une
  // mutation directe du store, AVANT que le trigger (retardé) ne s'exécute enfin.
  store.set('livreurs/d1', { name: 'D', isOnline: false });
  const result = await syncDriverPublicOnUpdate({ db, admin: fakeAdmin, driverId: 'd1' });
  assert.equal(result.written, true);
  assert.equal(store.get('driver_public/d1').isOnline, false, 'pas true : la relecture live gagne');
});

test('13. [concurrence] deux événements rapprochés : deux exécutions successives convergent '
  + "toutes deux vers l'état réel courant, quel que soit l'ordre d'arrivée", async () => {
  const { db, store } = fakeDb({ 'livreurs/d1': { isOnline: true } });
  await syncDriverPublicOnUpdate({ db, admin: fakeAdmin, driverId: 'd1' });
  assert.equal(store.get('driver_public/d1').isOnline, true);
  store.set('livreurs/d1', { isOnline: false });
  await syncDriverPublicOnUpdate({ db, admin: fakeAdmin, driverId: 'd1' });
  assert.equal(store.get('driver_public/d1').isOnline, false);
});

test('14. [concurrence] rejeu d\'un événement : même état source, aucune écriture supplémentaire '
  + '(idempotence de la reconciliation, pas seulement du correctif pur)', async () => {
  const { db, store, writes } = fakeDb({ 'livreurs/d1': { isOnline: true, name: 'D' } });
  await syncDriverPublicOnUpdate({ db, admin: fakeAdmin, driverId: 'd1' });
  const afterFirst = writes();
  await syncDriverPublicOnUpdate({ db, admin: fakeAdmin, driverId: 'd1' }); // rejeu
  assert.equal(writes(), afterFirst, 'aucune écriture : driver_public correspond déjà à livreurs');
  assert.deepEqual(store.get('driver_public/d1'), { isOnline: true, name: 'D' });
});

test('15. [concurrence] retry après échec : une nouvelle tentative relit l\'état courant, qui a '
  + "pu changer entre-temps, et n'écrase jamais avec la valeur de la tentative échouée", async () => {
  const { db, store } = fakeDb({ 'livreurs/d1': { isOnline: true } });
  // Première tentative « échouée » (simulée : on ne l'exécute pas, mais isOnline change ensuite
  // avant la tentative qui réussit réellement).
  store.set('livreurs/d1', { isOnline: false });
  const result = await syncDriverPublicOnUpdate({ db, admin: fakeAdmin, driverId: 'd1' }); // retry
  assert.equal(result.written, true);
  assert.equal(store.get('driver_public/d1').isOnline, false);
});

test('16. [concurrence] update isOnline suivi d\'un update isAvailable : le second événement ne '
  + "fait pas régresser le premier (chaque exécution lit l'état combiné réel, pas un avant/après "
  + "partiel)", async () => {
  const { db, store } = fakeDb({ 'livreurs/d1': { isOnline: true } });
  await syncDriverPublicOnUpdate({ db, admin: fakeAdmin, driverId: 'd1' });
  store.set('livreurs/d1', { isOnline: true, isAvailable: false });
  await syncDriverPublicOnUpdate({ db, admin: fakeAdmin, driverId: 'd1' });
  assert.deepEqual(store.get('driver_public/d1'), { isOnline: true, isAvailable: false });
});

test('17. [concurrence] update isOnDelivery suivi d\'un update isOnline : même propriété, deux '
  + 'champs disjoints convergent correctement sans s\'écraser mutuellement', async () => {
  const { db, store } = fakeDb({ 'livreurs/d1': { isOnDelivery: true } });
  await syncDriverPublicOnUpdate({ db, admin: fakeAdmin, driverId: 'd1' });
  store.set('livreurs/d1', { isOnDelivery: true, isOnline: false });
  await syncDriverPublicOnUpdate({ db, admin: fakeAdmin, driverId: 'd1' });
  assert.deepEqual(store.get('driver_public/d1'), { isOnDelivery: true, isOnline: false });
});

test('18. [concurrence] création suivie immédiatement d\'une mise à jour : les deux triggers '
  + 'partagent la même reconciliation, le résultat final reflète la dernière mise à jour', async () => {
  const { db, store } = fakeDb({ 'livreurs/new1': { name: 'Nouveau', isOnline: false } });
  await syncDriverPublicOnCreate({ db, admin: fakeAdmin, driverId: 'new1' });
  assert.deepEqual(store.get('driver_public/new1'), { name: 'Nouveau', isOnline: false });
  store.set('livreurs/new1', { name: 'Nouveau', isOnline: true });
  await syncDriverPublicOnUpdate({ db, admin: fakeAdmin, driverId: 'new1' });
  assert.deepEqual(store.get('driver_public/new1'), { name: 'Nouveau', isOnline: true });
});

test('19. [concurrence] projection GPS concurrente (écrite par S4, hors de ce module) : jamais '
  + 'lue, jamais écrasée par une reconciliation non-GPS exécutée au même moment', async () => {
  const { db, store } = fakeDb({
    'livreurs/d1': { isOnline: true },
    'driver_public/d1': { lat: 6.73, lng: -3.49, updatedAt: 42 }, // posée par S4, indépendamment
  });
  await syncDriverPublicOnUpdate({ db, admin: fakeAdmin, driverId: 'd1' });
  const doc = store.get('driver_public/d1');
  assert.equal(doc.lat, 6.73);
  assert.equal(doc.lng, -3.49);
  assert.equal(doc.updatedAt, 42);
  assert.equal(doc.isOnline, true);
});

// ── SEC-01 / S5.3.3 — SUPPRESSION (Phase 4, points 9-13) ────────────────────────────────────

test('20. [suppression] source supprimée avant le traitement d\'un événement update en retard : '
  + 'aucune valeur n\'est (re)projetée, les champs non-GPS déjà présents sont invalidés', async () => {
  const { db, store } = fakeDb({
    'driver_public/d1': { name: 'D', isOnline: true }, // projection existante, source déjà partie
  });
  const result = await syncDriverPublicOnUpdate({ db, admin: fakeAdmin, driverId: 'd1' });
  assert.equal(result.deleted, true);
  assert.equal(store.has('driver_public/d1'), false);
});

test('21. [suppression] source absente lors d\'un événement create (cas limite théorique : '
  + 'document supprimé avant que son propre trigger de création ne s\'exécute) : aucune '
  + 'projection fantôme créée', async () => {
  const { db, store } = fakeDb(); // ni livreurs/d1 ni driver_public/d1 n'existent
  const result = await syncDriverPublicOnCreate({ db, admin: fakeAdmin, driverId: 'd1' });
  assert.equal(result.written, false);
  assert.equal(result.reason, 'already-absent');
  assert.equal(store.has('driver_public/d1'), false);
});

test('22. [suppression] événement non-GPS retardé après une suppression réelle : les champs '
  + 'non-GPS sont invalidés mais la projection GPS (S4, toujours alimentée séparément) est '
  + 'préservée — jamais de suppression du document entier dans ce cas', async () => {
  const { db, store } = fakeDb({
    'driver_public/d1': { name: 'D', isOnline: true, lat: 6.73, lng: -3.49, updatedAt: 99 },
  });
  const result = await syncDriverPublicOnUpdate({ db, admin: fakeAdmin, driverId: 'd1' });
  assert.equal(result.invalidated, true);
  const doc = store.get('driver_public/d1');
  assert.equal('name' in doc, false);
  assert.equal('isOnline' in doc, false);
  assert.equal(doc.lat, 6.73);
  assert.equal(doc.lng, -3.49);
  assert.equal(doc.updatedAt, 99);
});

test('23. [suppression] suppression répétée : un événement de suppression en retard, exécuté '
  + "après qu'un livreur du même identifiant a été recréé, n'efface PAS la nouvelle projection", async () => {
  const { db, store } = fakeDb({
    'livreurs/d1': { name: 'Recréé' }, // le livreur a été recréé avant que l'événement retardé ne tourne
    'driver_public/d1': { name: 'Recréé' },
  });
  const result = await syncDriverPublicOnDelete({ db, driverId: 'd1' });
  assert.equal(result.deleted, false);
  assert.equal(result.reason, 'source-recreated');
  assert.equal(store.has('driver_public/d1'), true, 'la projection du livreur recréé doit survivre');
});

test('23b. [suppression] suppression répétée (cas normal) : appeler deux fois le trigger de '
  + 'suppression sans recréation reste sans erreur et sans effet au-delà de la première', async () => {
  const { db, store } = fakeDb({ 'driver_public/d1': { name: 'D' } });
  const r1 = await syncDriverPublicOnDelete({ db, driverId: 'd1' });
  assert.equal(r1.deleted, true);
  const r2 = await syncDriverPublicOnDelete({ db, driverId: 'd1' }); // rejeu
  assert.equal(r2.deleted, true); // delete() sur un doc déjà absent : pas une erreur
  assert.equal(store.has('driver_public/d1'), false);
});

test('24. [suppression] projection déjà absente : suppression sans erreur, aucune écriture '
  + 'inutile', async () => {
  const { db, writes } = fakeDb();
  await assert.doesNotReject(syncDriverPublicOnDelete({ db, driverId: 'ghost' }));
  assert.equal(writes() <= 1, true); // au plus l'appel .delete() lui-même (idempotent côté store)
});

// ── SEC-01 / S5.3.3 — SÉCURITÉ ET RÉGRESSION (Phase 4, points 14-20) ────────────────────────

test('25. [sécurité] whitelist strictement respectée de bout en bout (pas seulement au niveau '
  + 'de la fonction pure) : seuls les champs autorisés atteignent driver_public', async () => {
  const { db, store } = fakeDb({
    'livreurs/d1': {
      name: 'D', isOnline: true, wallet: 5000, phone: '0700000000', fcmToken: 'tok',
      ownerId: 'fleet-1', isSuspended: false, identifiant: 'ID-1',
    },
  });
  await syncDriverPublicOnUpdate({ db, admin: fakeAdmin, driverId: 'd1' });
  assert.deepEqual(Object.keys(store.get('driver_public/d1')).sort(), ['isOnline', 'name']);
});

test('26. [sécurité] champs sensibles jamais copiés même quand ils changent en même temps qu\'un '
  + 'champ whitelisté, de bout en bout', async () => {
  const { db, store } = fakeDb({ 'livreurs/d1': { name: 'D', wallet: 1000 } });
  await syncDriverPublicOnUpdate({ db, admin: fakeAdmin, driverId: 'd1' });
  store.set('livreurs/d1', { name: 'D2', wallet: 2000 });
  await syncDriverPublicOnUpdate({ db, admin: fakeAdmin, driverId: 'd1' });
  assert.deepEqual(store.get('driver_public/d1'), { name: 'D2' });
});

test('27. [sécurité] champs GPS jamais écrasés par une reconciliation create/update, de bout '
  + 'en bout (complète le test 19 côté création)', async () => {
  const { db, store } = fakeDb({
    'livreurs/new1': { name: 'D' },
    'driver_public/new1': { lat: 1, lng: 2, heading: 3, speed: 4, updatedAt: 5 },
  });
  await syncDriverPublicOnCreate({ db, admin: fakeAdmin, driverId: 'new1' });
  const doc = store.get('driver_public/new1');
  assert.equal(doc.lat, 1);
  assert.equal(doc.lng, 2);
  assert.equal(doc.heading, 3);
  assert.equal(doc.speed, 4);
  assert.equal(doc.updatedAt, 5);
});

test('28. [régression] idempotence confirmée de bout en bout (complète le test 14, formulation '
  + 'exigée par la Phase 4 du cahier des charges)', async () => {
  const { db, store, writes } = fakeDb({ 'livreurs/d1': { isOnline: true } });
  await syncDriverPublicOnUpdate({ db, admin: fakeAdmin, driverId: 'd1' });
  const w1 = writes();
  await syncDriverPublicOnUpdate({ db, admin: fakeAdmin, driverId: 'd1' });
  assert.equal(writes(), w1);
  assert.deepEqual(store.get('driver_public/d1'), { isOnline: true });
});

test('29. [régression] écriture inutile évitée : aucun appel .set()/.delete() si driver_public '
  + 'correspond déjà exactement à livreurs', async () => {
  const { db, writes } = fakeDb({
    'livreurs/d1': { name: 'D', isOnline: true },
    'driver_public/d1': { name: 'D', isOnline: true },
  });
  const result = await syncDriverPublicOnUpdate({ db, admin: fakeAdmin, driverId: 'd1' });
  assert.equal(result.written, false);
  assert.equal(result.reason, 'no-changes');
  assert.equal(writes(), 0);
});

test('30. [régression] erreur transactionnelle : une transaction qui échoue remonte l\'erreur à '
  + "l'appelant (laissée au retry de la plateforme), sans écriture partielle silencieuse", async () => {
  const failingDb = {
    collection: (name) => ({ doc: (id) => ({ __path: `${name}/${id}` }) }),
    runTransaction: async () => { throw new Error('unavailable'); },
  };
  await assert.rejects(
    syncDriverPublicOnUpdate({ db: failingDb, admin: fakeAdmin, driverId: 'd1' }),
    /unavailable/,
  );
  await assert.rejects(
    syncDriverPublicOnCreate({ db: failingDb, admin: fakeAdmin, driverId: 'd1' }),
    /unavailable/,
  );
  await assert.rejects(
    syncDriverPublicOnDelete({ db: failingDb, driverId: 'd1' }),
    /unavailable/,
  );
});

test('31. [régression] aucune régression sur les motifs exacts de S5.1 (goOffline) et S5.2 '
  + '(_saveToFirestore GPS + isOnline) une fois rejoués via la reconciliation live', async () => {
  // S5.1 : goOffline() n'écrit QUE isOnline:false sur livreurs.
  const { db: db1, store: store1 } = fakeDb({ 'livreurs/d1': { isOnline: true, wallet: 5000 } });
  await syncDriverPublicOnUpdate({ db: db1, admin: fakeAdmin, driverId: 'd1' });
  store1.set('livreurs/d1', { isOnline: false, wallet: 5000 });
  await syncDriverPublicOnUpdate({ db: db1, admin: fakeAdmin, driverId: 'd1' });
  assert.deepEqual(store1.get('driver_public/d1'), { isOnline: false });

  // S5.2/S4 : _saveToFirestore pose GPS + isOnline:true dans la même écriture livreurs ; ce
  // module ne doit synchroniser QUE isOnline, jamais les champs GPS (gérés par S4 séparément).
  const { db: db2, store: store2 } = fakeDb({
    'livreurs/d2': { isOnline: true, lat: 6.73, lng: -3.49, heading: 10, speed: 2, updatedAt: 123 },
  });
  await syncDriverPublicOnUpdate({ db: db2, admin: fakeAdmin, driverId: 'd2' });
  assert.deepEqual(store2.get('driver_public/d2'), { isOnline: true });
});

// ── Export, intégration et reproduction des documents réels de création (S5.3.1, non régressé) ─

test('32. export et intégration dans index.js : les trois triggers existent et sont des '
  + 'CloudFunction appelables', () => {
  // eslint-disable-next-line global-require
  const index = require('../index.js');
  assert.equal(typeof index.syncDriverPublicOnLivreurCreate, 'function');
  assert.equal(typeof index.syncDriverPublicOnLivreurUpdate, 'function');
  assert.equal(typeof index.syncDriverPublicOnLivreurDelete, 'function');
});

test('33. création/mise à jour partagent la même reconciliation (réutilisation, pas de logique '
  + 'dupliquée) — vérifié par lecture de code, pas par supposition', () => {
  const fs = require('node:fs');
  const path = require('node:path');
  const src = fs.readFileSync(path.join(__dirname, '..', 'driverPublicSync.js'), 'utf8');
  assert.ok(src.includes('return reconcileDriverPublicFromSource({ db, admin, driverId });'));
  assert.equal(
    (src.match(/return reconcileDriverPublicFromSource\(\{ db, admin, driverId \}\);/g) || []).length,
    2,
    'syncDriverPublicOnCreate ET syncDriverPublicOnUpdate doivent tous deux déléguer, sans dupliquer la logique',
  );
});

test('34. reproduit exactement le document créé par driver_requests_page.dart (admin) : '
  + 'photoUrl vide omis, isAvailable/isOnDelivery absents à juste titre', async () => {
  const { db, store } = fakeDb({
    'livreurs/d-admin': {
      name: 'Livreur Admin', phone: '0700000001', email: '', identifiant: 'ID-1',
      photoUrl: '', idPhotoUrl: 'https://x/id.jpg', selfieUrl: 'https://x/selfie.jpg',
      wallet: 0, isOnline: false, lat: 0, lng: 0, deliveries: 0,
      avgRating: 0.0, ratingCount: 0,
    },
  });
  await syncDriverPublicOnCreate({ db, admin: fakeAdmin, driverId: 'd-admin' });
  assert.deepEqual(store.get('driver_public/d-admin'),
    { name: 'Livreur Admin', isOnline: false, avgRating: 0, ratingCount: 0 });
});

test('35. reproduit exactement le document créé par fleetDriverCreation.js (flotte) : '
  + 'ownerId jamais projeté', async () => {
  const { db, store } = fakeDb({
    'livreurs/d-fleet': {
      name: 'Livreur Flotte', photoUrl: '', wallet: 0, isOnline: false,
      lat: 0, lng: 0, avgRating: 0.0, ratingCount: 0, ownerId: 'fleet-1',
    },
  });
  await syncDriverPublicOnCreate({ db, admin: fakeAdmin, driverId: 'd-fleet' });
  const doc = store.get('driver_public/d-fleet');
  assert.deepEqual(doc, { name: 'Livreur Flotte', isOnline: false, avgRating: 0, ratingCount: 0 });
  assert.equal('ownerId' in doc, false);
});
