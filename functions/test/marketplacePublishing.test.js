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

