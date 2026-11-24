'use strict';

/**
 * Idempotence PERSISTANTE des outils AZ IA — 100 % hors ligne.
 * Firestore est une doublure en mémoire dont les transactions sont
 * sérialisées, comme le fait réellement Firestore. Aucun appel réseau,
 * aucun modèle, aucun secret.
 */

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  createPersistentToolLedger, identify, isPersistentTool, COLLECTION, STALE_RUNNING_MS,
} = require('../azia/persistentToolLedger');

const fakeAdmin = {
  firestore: {
    FieldValue: { serverTimestamp: () => '__ts__' },
    Timestamp: { fromMillis: (ms) => ({ toMillis: () => ms }) },
  },
};

function makeDb(seed = {}) {
  const store = new Map(Object.entries(seed));
  const makeRef = (path) => ({
    path,
    id: path.split('/').pop(),
    get: async () => ({ exists: store.has(path), data: () => store.get(path) }),
    update: async (data) => { store.set(path, { ...(store.get(path) || {}), ...data }); },
  });
  let queue = Promise.resolve();
  return {
    store,
    collection: (name) => ({ doc: (id) => makeRef(`${name}/${id}`) }),
    // Firestore sérialise réellement les transactions concurrentes ; sans le
    // modéliser, la doublure laisserait passer deux réservations et testerait
    // elle-même plutôt que le code.
    runTransaction: (fn) => {
      const result = queue.then(() => fn({
        get: async (ref) => ref.get(),
        set: (ref, data) => store.set(ref.path, data),
        update: (ref, data) => store.set(ref.path, { ...(store.get(ref.path) || {}), ...data }),
      }));
      queue = result.catch(() => {});
      return result;
    },
  };
}

const RECHARGE = { uid: 'u1', conversationId: 'c1', name: 'initiate_wallet_recharge', input: { amount: 1000, operator: 'wave' } };

/** Compteur d'exécutions réelles du handler métier. */
function counter(result = { ok: true }) {
  const state = { count: 0 };
  state.run = async () => { state.count += 1; return result; };
  return state;
}

// ── Classification des outils ───────────────────────────────────────────────
test('classification : outils à effet durable vs lecture seule', () => {
  assert.equal(isPersistentTool({ name: 'initiate_wallet_recharge', confirmHandler: () => {} }), true);
  assert.equal(isPersistentTool({ name: 'cancel_order', confirmHandler: () => {} }), true);
  assert.equal(isPersistentTool({ name: 'create_support_ticket' }), true);
  assert.equal(isPersistentTool({ name: 'create_reminder' }), true);
  assert.equal(isPersistentTool({ name: 'remember_user_info' }), true);
  // Lecture seule : aucune réservation, donc aucun coût Firestore ajouté.
  for (const readOnly of ['get_wallet_balance', 'get_wallet_transactions', 'track_order',
    'search_restaurants', 'search_marketplace', 'search_real_estate', 'search_pharmacies',
    'track_ekbine_order']) {
    assert.equal(isPersistentTool({ name: readOnly }), false, `${readOnly} ne doit pas être persistant`);
  }
});

// ── A. Même requête deux fois séquentiellement ──────────────────────────────
test('A. même requête deux fois → handler exécuté UNE fois, résultat réutilisé', async () => {
  const db = makeDb();
  const ledger = createPersistentToolLedger({ db, admin: fakeAdmin });
  const c = counter({ status: 'awaiting_confirmation', actionId: 'a1' });

  const first = await ledger.execute(RECHARGE, c.run);
  const second = await ledger.execute(RECHARGE, c.run);

  assert.equal(c.count, 1, 'HANDLER EXECUTION COUNT doit valoir 1');
  assert.equal(first.executed, true);
  assert.equal(second.executed, false);
  assert.equal(second.reused, true);
  assert.deepEqual(second.result, first.result, 'le résultat enregistré est réutilisé');
});

// ── B. Concurrence ──────────────────────────────────────────────────────────
test('B. deux invocations concurrentes → handler exécuté UNE fois', async () => {
  const db = makeDb();
  const ledger = createPersistentToolLedger({ db, admin: fakeAdmin });
  const c = counter();
  let release;
  const gate = new Promise((r) => { release = r; });
  const slowRun = async () => { await gate; return c.run(); };

  const a = ledger.execute(RECHARGE, slowRun);
  const b = ledger.execute(RECHARGE, slowRun);   // arrive pendant l'exécution de A
  release();
  const [ra, rb] = await Promise.all([a, b]);

  assert.equal(c.count, 1, 'une seule exécution malgré la concurrence');
  const executed = [ra, rb].filter((r) => r.executed);
  assert.equal(executed.length, 1);
  const duplicate = [ra, rb].find((r) => !r.executed);
  assert.equal(duplicate.result.status, 'duplicate_in_progress', 'la seconde reçoit un état contrôlé');
});

// ── C/D. Indépendance du fournisseur ────────────────────────────────────────
test('C. Gemini puis Claude (même action logique) → handler UNE fois', async () => {
  const db = makeDb();
  const ledger = createPersistentToolLedger({ db, admin: fakeAdmin });
  const c = counter();
  // Les identifiants natifs diffèrent (gemini-0-0-x vs toolu_abc) mais
  // n'entrent JAMAIS dans la clé logique.
  await ledger.execute({ ...RECHARGE, nativeId: 'gemini-0-0-initiate_wallet_recharge' }, c.run);
  await ledger.execute({ ...RECHARGE, nativeId: 'toolu_01ABC' }, c.run);
  assert.equal(c.count, 1);
});

test('D. Claude puis Gemini → handler UNE fois', async () => {
  const db = makeDb();
  const ledger = createPersistentToolLedger({ db, admin: fakeAdmin });
  const c = counter();
  await ledger.execute({ ...RECHARGE, nativeId: 'toolu_01ABC' }, c.run);
  await ledger.execute({ ...RECHARGE, nativeId: 'gemini-1-0-initiate_wallet_recharge' }, c.run);
  assert.equal(c.count, 1);
});

test('la clé logique ne dépend ni du fournisseur ni de l\'ordre des arguments', () => {
  const a = identify({ uid: 'u1', conversationId: 'c1', name: 't', input: { b: 2, a: 1 } });
  const b = identify({ uid: 'u1', conversationId: 'c1', name: 't', input: { a: 1, b: 2 } });
  assert.equal(a, b, 'arguments équivalents → même identité logique');
  assert.ok(a.startsWith('tool_'));
  assert.ok(!a.includes('u1'), 'la clé est hachée : aucun argument brut ne transparaît');
});

// ── E. Redémarrage / nouvelle instance ──────────────────────────────────────
test('E. nouvelle instance (mémoire perdue) → aucune réexécution', async () => {
  const db = makeDb();
  const c = counter();
  // Invocation A : ledger créé, action exécutée.
  const ledgerA = createPersistentToolLedger({ db, admin: fakeAdmin });
  await ledgerA.execute(RECHARGE, c.run);

  // Invocation B : instance neuve, AUCUN état mémoire partagé.
  const ledgerB = createPersistentToolLedger({ db, admin: fakeAdmin });
  const again = await ledgerB.execute(RECHARGE, c.run);

  assert.equal(c.count, 1, 'la protection ne dépend d\'aucun Map mémoire');
  assert.equal(again.reused, true);
});

// ── F/G. Pending actions et confirmation ────────────────────────────────────
test('F. même demande sensible deux fois → une seule action en attente', async () => {
  const db = makeDb();
  const ledger = createPersistentToolLedger({ db, admin: fakeAdmin });
  const created = [];
  const run = async () => {
    const actionId = `pending_${created.length + 1}`;
    created.push(actionId);
    return { status: 'awaiting_confirmation', actionId };
  };
  await ledger.execute(RECHARGE, run);
  const second = await ledger.execute(RECHARGE, run);
  assert.equal(created.length, 1, 'une seule action en attente créée');
  assert.equal(second.result.actionId, 'pending_1', 'la même action est référencée');
});

test('G. un échec précédent n\'est jamais rejoué automatiquement', async () => {
  const db = makeDb();
  const ledger = createPersistentToolLedger({ db, admin: fakeAdmin });
  let calls = 0;
  await assert.rejects(ledger.execute(RECHARGE, async () => {
    calls += 1;
    throw new Error('panne pendant l\'écriture');
  }));
  const retry = await ledger.execute(RECHARGE, async () => { calls += 1; return { ok: true }; });
  assert.equal(calls, 1, 'un effet incertain ne doit jamais être rejoué en aveugle');
  assert.equal(retry.result.status, 'previous_attempt_failed');
});

// ── H/I. Outils financiers et métier ────────────────────────────────────────
test('H. remboursement / annulation → une seule exécution', async () => {
  const db = makeDb();
  const ledger = createPersistentToolLedger({ db, admin: fakeAdmin });
  const c = counter({ refunded: 2000 });
  const cancel = { uid: 'u1', conversationId: 'c1', name: 'cancel_order', input: { orderId: 'o1' } };
  await ledger.execute(cancel, c.run);
  await ledger.execute(cancel, c.run);
  await ledger.execute(cancel, c.run);
  assert.equal(c.count, 1, 'aucun double remboursement');
});

test('I. création de commande → un seul document métier', async () => {
  const db = makeDb();
  const ledger = createPersistentToolLedger({ db, admin: fakeAdmin });
  const orders = [];
  const run = async () => { orders.push(`order_${orders.length + 1}`); return { orderId: orders.at(-1) }; };
  const create = { uid: 'u1', conversationId: 'c1', name: 'create_delivery_order', input: { deliveryLat: 6.7, deliveryLng: -3.5 } };
  await ledger.execute(create, run);
  await ledger.execute(create, run);
  assert.equal(orders.length, 1, 'deux requêtes identiques ne créent pas deux commandes');
});

// ── J/K. Actions réellement distinctes ──────────────────────────────────────
test('J. arguments différents → actions distinctes', async () => {
  const db = makeDb();
  const ledger = createPersistentToolLedger({ db, admin: fakeAdmin });
  const c = counter();
  await ledger.execute(RECHARGE, c.run);
  await ledger.execute({ ...RECHARGE, input: { amount: 2000, operator: 'wave' } }, c.run);
  assert.equal(c.count, 2, 'une recharge de 2000 n\'est pas la même action que 1000');
});

test('K. utilisateurs différents → actions distinctes', async () => {
  const db = makeDb();
  const ledger = createPersistentToolLedger({ db, admin: fakeAdmin });
  const c = counter();
  await ledger.execute(RECHARGE, c.run);
  await ledger.execute({ ...RECHARGE, uid: 'u2' }, c.run);
  assert.equal(c.count, 2, 'la clé est cloisonnée par utilisateur');
});

test('K bis. conversations différentes → actions distinctes', async () => {
  const db = makeDb();
  const ledger = createPersistentToolLedger({ db, admin: fakeAdmin });
  const c = counter();
  await ledger.execute(RECHARGE, c.run);
  await ledger.execute({ ...RECHARGE, conversationId: 'c2' }, c.run);
  assert.equal(c.count, 2);
});

// ── Réservations abandonnées, confidentialité, TTL ──────────────────────────
test('une réservation abandonnée n\'est pas rejouée en aveugle', async () => {
  const db = makeDb();
  let clock = 1_000_000;
  const ledger = createPersistentToolLedger({ db, admin: fakeAdmin, now: () => clock });
  const c = counter();
  const slow = async () => { await new Promise((r) => setTimeout(r, 5)); return c.run(); };
  const pending = ledger.execute(RECHARGE, slow);
  clock += STALE_RUNNING_MS + 1;                       // l'instance d'origine est réputée morte
  const later = await ledger.execute(RECHARGE, c.run);
  await pending;
  assert.equal(later.executed, false, 'aucune réexécution : l\'effet a pu se produire');
  assert.equal(c.count, 1);
});

test('aucune donnée sensible n\'est persistée dans le ledger', async () => {
  const db = makeDb();
  const ledger = createPersistentToolLedger({ db, admin: fakeAdmin });
  await ledger.execute({
    uid: 'u1', conversationId: 'c1', name: 'initiate_wallet_recharge',
    input: { amount: 1000, operator: 'wave', phone: '0700000000' },
  }, async () => ({ ok: true }));
  const stored = JSON.stringify([...db.store.entries()]);
  assert.ok(!stored.includes('0700000000'), 'le numéro de téléphone ne doit jamais être stocké');
  assert.ok(!stored.includes('"phone"'), 'aucun argument brut n\'est persisté');
});

test('le document porte une date d\'expiration exploitable par un TTL', async () => {
  const db = makeDb();
  const ledger = createPersistentToolLedger({ db, admin: fakeAdmin, ttlMs: 60_000, now: () => 1_000 });
  const { key } = await ledger.execute(RECHARGE, async () => ({ ok: true }));
  const doc = db.store.get(`${COLLECTION}/${key}`);
  assert.equal(doc.expiresAt.toMillis(), 61_000);
  assert.equal(doc.status, 'completed');
  assert.equal(doc.toolName, 'initiate_wallet_recharge');
});

// ── LOT GEMINI 4 : fenêtre d'idempotence par classe d'outil ────────────────
const {
  ttlForTool, NON_FINANCIAL_TTL_MS, FINANCIAL_TTL_MS,
} = require('../azia/persistentToolLedger');

test('TTL : fenêtre longue pour les outils financiers/irréversibles', () => {
  for (const name of ['initiate_wallet_recharge', 'cancel_order', 'create_delivery_order',
    'create_marketplace_order', 'create_restaurant_order', 'create_pharmacie_order',
    'create_ekbine_order', 'create_shopping_order', 'request_property_visit']) {
    assert.equal(ttlForTool(name), FINANCIAL_TTL_MS, `${name} doit garder la fenêtre longue`);
  }
  assert.ok(FINANCIAL_TTL_MS > NON_FINANCIAL_TTL_MS, 'jamais réduite sous la fenêtre courte');
});

test('TTL : fenêtre courte pour les outils réversibles sans impact financier', () => {
  for (const name of ['create_support_ticket', 'create_reminder',
    'remember_user_info', 'remember_named_address']) {
    assert.equal(ttlForTool(name), NON_FINANCIAL_TTL_MS);
  }
});

test('TTL : surchargeable par configuration, sans redéploiement', () => {
  process.env.AI_TOOL_IDEMPOTENCY_FINANCIAL_TTL_MS = String(90 * 24 * 3600 * 1000);
  assert.equal(ttlForTool('cancel_order'), 90 * 24 * 3600 * 1000);
  delete process.env.AI_TOOL_IDEMPOTENCY_FINANCIAL_TTL_MS;
  assert.equal(ttlForTool('cancel_order'), FINANCIAL_TTL_MS, 'retour au défaut si non configuré');
});

test('TTL : expiresAt est un Timestamp Firestore, calculé selon la classe', async () => {
  const db = makeDb();
  const ledger = createPersistentToolLedger({ db, admin: fakeAdmin, now: () => 1_000 });
  const { key } = await ledger.execute(RECHARGE, async () => ({ ok: true }));
  const doc = db.store.get(`${COLLECTION}/${key}`);
  assert.equal(typeof doc.expiresAt.toMillis, 'function', 'type compatible TTL Firestore');
  assert.equal(doc.expiresAt.toMillis(), 1_000 + FINANCIAL_TTL_MS);

  const ledger2 = createPersistentToolLedger({ db, admin: fakeAdmin, now: () => 1_000 });
  const rappel = { uid: 'u1', conversationId: 'c1', name: 'create_reminder', input: { atIso: 'x' } };
  const { key: k2 } = await ledger2.execute(rappel, async () => ({ ok: true }));
  assert.equal(db.store.get(`${COLLECTION}/${k2}`).expiresAt.toMillis(), 1_000 + NON_FINANCIAL_TTL_MS);
});

// ── États et concurrence, sans dépendre du vrai TTL Firestore ──────────────
test('état completed non expiré → résultat réutilisé, aucune réexécution', async () => {
  const db = makeDb();
  const ledger = createPersistentToolLedger({ db, admin: fakeAdmin });
  const c = counter({ orderId: 'o1' });
  await ledger.execute(RECHARGE, c.run);
  const again = await ledger.execute(RECHARGE, c.run);
  assert.equal(c.count, 1);
  assert.equal(again.reused, true);
  assert.deepEqual(again.result, { orderId: 'o1' });
});

test('état running non expiré → doublon bloqué', async () => {
  const db = makeDb();
  const ledger = createPersistentToolLedger({ db, admin: fakeAdmin });
  await ledger.reserve(RECHARGE);                 // réservation laissée en cours
  const c = counter();
  const duplicate = await ledger.execute(RECHARGE, c.run);
  assert.equal(c.count, 0, 'aucune exécution tant que la réservation est active');
  assert.equal(duplicate.result.status, 'duplicate_in_progress');
});

test('état abandoned non expiré → toujours pas de réexécution', async () => {
  const db = makeDb();
  const ledger = createPersistentToolLedger({ db, admin: fakeAdmin });
  const { key } = await ledger.reserve(RECHARGE);
  db.store.set(`${COLLECTION}/${key}`, { ...db.store.get(`${COLLECTION}/${key}`), status: 'abandoned' });
  const c = counter();
  const after = await ledger.execute(RECHARGE, c.run);
  assert.equal(c.count, 0, 'un effet possiblement déjà produit n\'est jamais rejoué');
  assert.equal(after.result.status, 'previous_attempt_failed');
});

test('expiresAt dépassé ne vaut JAMAIS autorisation de rejouer', async () => {
  const db = makeDb();
  // Document expiré depuis longtemps, mais toujours présent.
  const ledger = createPersistentToolLedger({ db, admin: fakeAdmin, now: () => 10_000 });
  const { key } = await ledger.execute(RECHARGE, async () => ({ ok: true }));
  db.store.set(`${COLLECTION}/${key}`, {
    ...db.store.get(`${COLLECTION}/${key}`),
    expiresAt: { toMillis: () => 1 },             // expiré
  });
  const c = counter();
  const later = await ledger.execute(RECHARGE, c.run);
  assert.equal(c.count, 0, 'le code ne lit jamais expiresAt comme un droit de rejeu');
  assert.equal(later.reused, true);
});
