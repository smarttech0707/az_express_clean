'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  PRIVATE_LIFETIME_MS,
  assertPrivatePublicationAllowed,
  publicationSystemFields,
  shouldExpireProduct,
  buildExpireMarketplaceProducts,
} = require('../marketplacePublishing');

class FakeTimestamp {
  constructor(ms) { this.ms = ms; }
  toMillis() { return this.ms; }
  static fromMillis(ms) { return new FakeTimestamp(ms); }
  static now() { return new FakeTimestamp(FakeTimestamp.nowMs); }
}
FakeTimestamp.nowMs = Date.UTC(2026, 7, 24, 12);

test('particulier: la quatrième annonce active est refusée', () => {
  assert.throws(
    () => assertPrivatePublicationAllowed({ isProfessional: false, activeCount: 3 }),
    (error) => error.code === 'resource-exhausted' && error.message.includes('3 annonces actives'),
  );
});

test('vendeur professionnel actif: aucune limite de publication', () => {
  assert.doesNotThrow(() =>
    assertPrivatePublicationAllowed({ isProfessional: true, activeCount: 500 }));
});

test('une annonce hidden ne compte pas dans la limite active', () => {
  const products = [
    { status: 'active' },
    { status: 'active' },
    { status: 'hidden' },
  ];
  const activeCount = products.filter((product) => product.status === 'active').length;
  assert.doesNotThrow(() =>
    assertPrivatePublicationAllowed({ isProfessional: false, activeCount }));
});

test('republication particulier: remet active avec exactement 15 jours', () => {
  const now = new FakeTimestamp(FakeTimestamp.nowMs);
  const fields = publicationSystemFields({
    seller: null,
    isProfessional: false,
    now,
    timestamp: FakeTimestamp,
  });
  assert.equal(fields.status, 'active');
  assert.equal(fields.expiresAt.toMillis(), now.toMillis() + PRIVATE_LIFETIME_MS);
});

test('vendeur professionnel: publication active sans expiration', () => {
  const fields = publicationSystemFields({
    seller: { verified: true, vipStatus: 'active', priorityLevel: 3 },
    isProfessional: true,
    now: new FakeTimestamp(FakeTimestamp.nowMs),
    timestamp: FakeTimestamp,
  });
  assert.equal(fields.status, 'active');
  assert.equal(fields.expiresAt, null);
  assert.equal(fields.sellerVerified, true);
  assert.equal(fields.priorityLevel, 3);
});

test('annonce sans expiresAt: ne doit jamais expirer rétroactivement', () => {
  assert.equal(shouldExpireProduct({ status: 'active' }, FakeTimestamp.nowMs), false);
});

test('tâche quotidienne: une annonce expirée passe réellement en hidden', async () => {
  const writes = [];
  const expiredDoc = {
    ref: { path: 'marketplace_products/expired' },
    data: () => ({ status: 'active', expiresAt: new FakeTimestamp(FakeTimestamp.nowMs - 1) }),
  };
  const snapshot = { empty: false, size: 1, docs: [expiredDoc] };
  const query = {
    where() { return this; },
    orderBy() { return this; },
    limit() { return this; },
    startAfter() { return this; },
    async get() { return snapshot; },
  };
  const db = {
    collection() { return query; },
    batch() {
      return {
        update(ref, data) { writes.push({ ref, data }); },
        async commit() {},
      };
    },
  };
  const admin = {
    firestore: {
      Timestamp: FakeTimestamp,
      FieldValue: { serverTimestamp: () => 'SERVER_TIMESTAMP' },
    },
  };

  const result = await buildExpireMarketplaceProducts({ db, admin })();
  assert.equal(result.expired, 1);
  assert.equal(writes.length, 1);
  assert.equal(writes[0].data.status, 'hidden');
});


// ── Idempotence de publishMarketplaceProduct ────────────────────────────────

function fakePublishDb() {
  const docs = new Map();
  const ref = (col, id) => ({ col, id, path: `${col}/${id}`,
    get: async () => ({ exists: false, data: () => null }) });
  let auto = 0;
  const db = {
    docs,
    collection: (col) => ({
      doc: (id) => ref(col, id ?? `auto${String(++auto).padStart(16, '0')}XXXX`),
      where() { return this; },
      limit() { return this; },
    }),
    runTransaction: async (fn) => fn({
      get: async (target) => {
        if (target.path) {
          const data = docs.get(target.path);
          return { exists: data !== undefined, data: () => data };
        }
        return { size: [...docs.values()].filter((d) => d.status === 'active').length };
      },
      set: (target, data) => { docs.set(target.path, data); },
    }),
  };
  return db;
}

const publishAdmin = { firestore: { Timestamp: { now: () => ({ toMillis: () => FakeTimestamp.nowMs }),
  fromMillis: (ms) => new FakeTimestamp(ms) } } };
const publishRequest = (uid, extra = {}) => ({
  auth: { uid, token: { firebase: { sign_in_provider: 'password' } } },
  data: { product: { title: 'iPhone 11', price: 80000 }, ...extra },
});

test('publication: même publicationId rejoué => une seule annonce, même identifiant', async () => {
  const { buildPublishMarketplaceProduct } = require('../marketplacePublishing');
  const db = fakePublishDb();
  const handler = buildPublishMarketplaceProduct({ db, admin: publishAdmin });
  const publicationId = 'AbCdEfGhIjKlMnOpQrSt';
  const first = await handler(publishRequest('u1', { publicationId }));
  const retry = await handler(publishRequest('u1', { publicationId }));
  assert.equal(first.productId, publicationId);
  assert.equal(retry.productId, publicationId);
  assert.equal(retry.duplicate, true);
  assert.equal(db.docs.size, 1);
});

test('publication: deux publicationId différents restent deux annonces', async () => {
  const { buildPublishMarketplaceProduct } = require('../marketplacePublishing');
  const db = fakePublishDb();
  const handler = buildPublishMarketplaceProduct({ db, admin: publishAdmin });
  await handler(publishRequest('u1', { publicationId: 'AAAAAAAAAAAAAAAAAAAA' }));
  await handler(publishRequest('u1', { publicationId: 'BBBBBBBBBBBBBBBBBBBB' }));
  assert.equal(db.docs.size, 2);
});

test('publication: sans publicationId (ancien client) comportement inchangé', async () => {
  const { buildPublishMarketplaceProduct } = require('../marketplacePublishing');
  const db = fakePublishDb();
  const handler = buildPublishMarketplaceProduct({ db, admin: publishAdmin });
  await handler(publishRequest('u1'));
  await handler(publishRequest('u1'));
  assert.equal(db.docs.size, 2);
});

test('publication: publicationId d\'un autre vendeur refusé, document intact', async () => {
  const { buildPublishMarketplaceProduct } = require('../marketplacePublishing');
  const db = fakePublishDb();
  const handler = buildPublishMarketplaceProduct({ db, admin: publishAdmin });
  const publicationId = 'CCCCCCCCCCCCCCCCCCCC';
  await handler(publishRequest('u1', { publicationId }));
  await assert.rejects(handler(publishRequest('u2', { publicationId })),
    (e) => e.code === 'already-exists');
  assert.equal(db.docs.get(`marketplace_products/${publicationId}`).sellerId, 'u1');
});

test('publication: publicationId mal formé refusé', async () => {
  const { buildPublishMarketplaceProduct } = require('../marketplacePublishing');
  const handler = buildPublishMarketplaceProduct({ db: fakePublishDb(), admin: publishAdmin });
  await assert.rejects(handler(publishRequest('u1', { publicationId: '../etc' })),
    (e) => e.code === 'invalid-argument');
});
