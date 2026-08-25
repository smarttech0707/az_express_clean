'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  planMigration,
  runMigration,
  rollbackReport,
  assertCliAuthorization,
} = require('../scripts/migrateAbengourouZones');

function city(id = 'city-abg', overrides = {}) {
  return {
    id,
    data: {
      name: 'Abengourou',
      type: 'ville',
      lat: 6.7273,
      lng: -3.4961,
      ...overrides,
    },
  };
}

function makeFakeDb(documents) {
  const store = new Map(documents.map(({ id, data }) => [id, structuredClone(data)]));
  let collectionReads = 0;
  let writes = 0;

  function documentRef(id) {
    return {
      id,
      get: async () => ({
        exists: store.has(id),
        data: () => structuredClone(store.get(id)),
      }),
    };
  }

  const db = {
    collection(name) {
      assert.equal(name, 'zones_livraison');
      return {
        get: async () => {
          collectionReads++;
          return {
            docs: [...store.entries()].map(([id, data]) => ({
              id,
              data: () => structuredClone(data),
            })),
          };
        },
        doc: documentRef,
      };
    },
    batch() {
      const pending = [];
      return {
        set(ref, patch, options) {
          assert.deepEqual(options, { merge: true });
          pending.push({ id: ref.id, patch });
        },
        async commit() {
          for (const { id, patch } of pending) {
            const resolved = {};
            for (const [field, value] of Object.entries(patch)) {
              if (value === DELETE_SENTINEL) continue;
              resolved[field] = value;
            }
            const current = store.get(id) || {};
            for (const [field, value] of Object.entries(patch)) {
              if (value === DELETE_SENTINEL) delete current[field];
            }
            store.set(id, { ...current, ...resolved });
            writes++;
          }
        },
      };
    },
  };
  return {
    db,
    store,
    get collectionReads() { return collectionReads; },
    get writes() { return writes; },
  };
}

const DELETE_SENTINEL = Symbol('delete');
const fakeAdmin = {
  firestore: { FieldValue: { delete: () => DELETE_SENTINEL } },
};

test('cas nominal : classe, propose sans copier de coordonnées et lit une fois', async () => {
  const fake = makeFakeDb([
    city(),
    {
      id: 'commerce',
      data: { name: 'Commerce', type: 'quartier', parentName: 'Abengourou' },
    },
    { id: 'ailleurs', data: { name: 'Bondoukou', type: 'ville' } },
  ]);

  const { report } = await runMigration({ db: fake.db });
  assert.equal(fake.collectionReads, 1);
  assert.equal(fake.writes, 0);
  assert.deepEqual(report.summary, {
    total: 3,
    ville_cible: 1,
    enfant_prouve: 1,
    autre: 1,
    conflit: 0,
    deja_conforme: 0,
    a_ecrire: 2,
  });
  const target = report.documents.find((entry) => entry.id === 'city-abg');
  assert.equal(target.proposed.coordinateSource, 'own');
  assert.equal(Object.hasOwn(target.proposed, 'radiusKm'), false);
  const child = report.documents.find((entry) => entry.id === 'commerce');
  assert.deepEqual(child.proposed, {
    cityId: 'abengourou',
    parentZoneId: 'city-abg',
    normalizedName: 'commerce',
    aliases: [],
    coordinateSource: 'unknown',
    isServiceable: false,
  });
  assert.equal(Object.hasOwn(child.proposed, 'lat'), false);
  assert.equal(Object.hasOwn(child.proposed, 'lng'), false);
  assert.equal(child.before.parentName, 'Abengourou');
});

test('ville absente : refuse la migration', () => {
  const report = planMigration([
    { id: 'q1', data: { name: 'Commerce', type: 'quartier' } },
  ]);
  assert.equal(report.eligibleForApply, false);
  assert.equal(report.refusal.code, 'TARGET_CITY_NOT_FOUND');
  assert.equal(report.summary.autre, 1);
  assert.equal(report.summary.a_ecrire, 0);
});

test('ville absente : apply refuse sans aucune écriture', async () => {
  const fake = makeFakeDb([
    { id: 'q1', data: { name: 'Commerce', type: 'quartier' } },
  ]);
  await assert.rejects(
    runMigration({ db: fake.db, mode: 'apply' }),
    { code: 'TARGET_CITY_NOT_FOUND' },
  );
  assert.equal(fake.writes, 0);
});

test('deux villes correspondantes : refuse la migration', () => {
  const report = planMigration([city('c1'), city('c2')]);
  assert.equal(report.eligibleForApply, false);
  assert.equal(report.refusal.code, 'MULTIPLE_TARGET_CITIES');
  assert.equal(report.summary.a_ecrire, 0);
});

test('document en conflit : le signale et ne propose aucune écriture', () => {
  const report = planMigration([
    city(),
    {
      id: 'conflict',
      data: {
        name: 'Commerce',
        parentName: 'Abengourou',
        cityId: 'agnibilekrou',
      },
    },
  ]);
  const conflict = report.documents.find((entry) => entry.id === 'conflict');
  assert.equal(conflict.category, 'conflit');
  assert.equal(conflict.proposed, null);
  assert.equal(report.summary.conflit, 1);
});

test('rejeu après interruption : ignore le conforme et termine le restant', async () => {
  const conformChild = {
    name: 'Commerce',
    type: 'quartier',
    parentName: 'Abengourou',
    cityId: 'abengourou',
    parentZoneId: 'city-abg',
    normalizedName: 'commerce',
    aliases: [],
    coordinateSource: 'unknown',
    isServiceable: false,
  };
  const fake = makeFakeDb([
    city('city-abg', {
      cityId: 'abengourou',
      normalizedName: 'abengourou',
      aliases: [],
      coordinateSource: 'own',
      isServiceable: false,
    }),
    { id: 'commerce', data: conformChild },
    {
      id: 'plateau',
      data: { name: 'Plateau', type: 'quartier', parentName: 'Abengourou' },
    },
  ]);

  let reportCapturedBeforeWrite = false;
  const result = await runMigration({
    db: fake.db,
    mode: 'apply',
    beforeApply: async (report) => {
      assert.equal(fake.writes, 0);
      assert.equal(report.summary.a_ecrire, 1);
      reportCapturedBeforeWrite = true;
    },
  });
  assert.equal(reportCapturedBeforeWrite, true);
  assert.deepEqual(result.report.apply.applied, ['plateau']);
  assert.equal(fake.writes, 1);
  assert.equal(fake.store.get('plateau').cityId, 'abengourou');
  assert.deepEqual(fake.store.get('commerce'), conformChild);
});

test('rollback préserve une modification admin postérieure champ par champ', async () => {
  const before = city();
  const report = planMigration([before]);
  const proposed = report.documents[0].proposed;
  const fake = makeFakeDb([{
    id: before.id,
    data: { ...before.data, ...proposed, aliases: ['modifie-par-admin'] },
  }]);

  const result = await rollbackReport({
    db: fake.db,
    admin: fakeAdmin,
    report,
  });
  const restored = fake.store.get(before.id);
  assert.equal(Object.hasOwn(restored, 'cityId'), false);
  assert.equal(Object.hasOwn(restored, 'coordinateSource'), false);
  assert.deepEqual(restored.aliases, ['modifie-par-admin']);
  assert.deepEqual(result.preserved, [{
    id: before.id,
    field: 'aliases',
    reason: 'modification_admin_posterieure',
  }]);
});

test('apply exige le drapeau explicite de confirmation', () => {
  assert.throws(
    () => assertCliAuthorization({ mode: 'apply', applyConfirmation: null }),
    /confirm-apply=ABENGOUROU/,
  );
  assert.doesNotThrow(() => assertCliAuthorization({
    mode: 'apply',
    applyConfirmation: 'ABENGOUROU',
  }));
});
