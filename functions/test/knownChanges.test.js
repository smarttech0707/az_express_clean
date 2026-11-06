'use strict';

// Mission 7E-55 : annexe des changements connus. Données entièrement simulées ; aucune valeur réelle de jeton.
const test = require('node:test');
const assert = require('node:assert/strict');
const kc = require('../../scripts/restaurant-v2-pilot/knownChanges');

const LOT = 't7e-lot-1';
const TOKEN = 'fake-token-for-test-only';
const entry = (over = {}) => ({
  path: 'clients/t7e-client', field: 'fcmToken', fingerprint: kc.fingerprintOf(TOKEN),
  observedAt: '2026-11-06T10:43:06Z', justification: 'jeton enregistré automatiquement à la connexion', ...over,
});
const annex = (entries = [entry()]) => ({ version: 1, lot: LOT, entries });
const classify = (data, a = annex(), docPath = 'clients/t7e-client', fields = Object.keys(data).filter((k) => /fcm|token|phone/i.test(k))) =>
  kc.classifySensitive({ docPath, data, sensitiveFields: fields, annex: a });

test('exception exacte reconnue : même chemin, même champ, même empreinte', () => {
  const r = classify({ fcmToken: TOKEN });
  assert.deepEqual(r.known, ['fcmToken']);
  assert.deepEqual(r.unexplained, []);
});

test('empreinte modifiée (jeton renouvelé) = conflit', () => {
  const r = classify({ fcmToken: `${TOKEN}-renouvele` });
  assert.equal(r.known.length, 0);
  assert.match(r.unexplained[0].reason, /empreinte différente/);
});

test('sans annexe : tout champ sensible reste un conflit', () => {
  assert.equal(classify({ fcmToken: TOKEN }, null).unexplained.length, 1);
});

test('autre document, autre champ, valeur absente ou non textuelle = conflit', () => {
  assert.equal(classify({ fcmToken: TOKEN }, annex(), 'livreurs/t7e-driver').unexplained.length, 1);
  assert.equal(classify({ phone: '0102' }).unexplained.length, 1);
  assert.equal(classify({ fcmToken: '' }, annex(), 'clients/t7e-client', ['fcmToken']).unexplained.length, 1);
  assert.equal(classify({ fcmToken: 42 }, annex(), 'clients/t7e-client', ['fcmToken']).unexplained.length, 1);
});

test('exception + champ sensible supplémentaire : seul le second est un conflit', () => {
  const r = classify({ fcmToken: TOKEN, phoneNumber: '0102' });
  assert.deepEqual(r.known, ['fcmToken']);
  assert.deepEqual(r.unexplained.map((x) => x.field), ['phoneNumber']);
});

test('empreinte provisoire (préfixe) : aucune exception reconnue tant que l’empreinte complète n’est pas vérifiée', () => {
  const r = classify({ fcmToken: TOKEN }, annex([entry({ fingerprint: kc.fingerprintOf(TOKEN).slice(0, 12) })]));
  assert.equal(r.known.length, 0);
  assert.match(r.unexplained[0].reason, /provisoire/);
  assert.equal(kc.fingerprintOf(TOKEN).length, kc.FULL_FINGERPRINT);
});

test('annexe valide acceptée', () => {
  assert.doesNotThrow(() => kc.validateAnnex(annex(), LOT));
  assert.doesNotThrow(() => kc.validateAnnex(annex([]), LOT));
});

test('annexe invalide refusée : lot, version, entrée hors liste blanche, valeur en clair, doublon, empreinte, date', () => {
  const bad = (a) => assert.throws(() => kc.validateAnnex(a, LOT), { code: 'INVALID_KNOWN_CHANGES' });
  bad(null); bad([]); bad({ ...annex(), lot: 'autre' }); bad({ ...annex(), version: 2 }); bad({ version: 1, lot: LOT });
  bad(annex([entry({ field: 'phoneNumber' })]));
  bad(annex([entry({ path: 'livreurs/t7e-driver' })]));
  bad(annex([entry({ value: TOKEN })]));
  bad(annex([entry(), entry()]));
  bad(annex([entry({ fingerprint: 'abc' })]));
  bad(annex([entry({ fingerprint: 'ZZZZZZZZZZ' })]));
  bad(annex([entry({ observedAt: 'hier' })]));
  bad(annex([entry({ justification: '  ' })]));
});

test('annexe invalide dans collectInventory : refus avant toute lecture', async () => {
  const { collectInventory } = require('../../scripts/restaurant-v2-pilot/cleanup');
  await assert.rejects(collectInventory({ manifest: null, annex: annex([entry({ field: 'x' })]) }), { code: 'INVALID_KNOWN_CHANGES' });
});

test('l’annexe ne contient et n’affiche jamais la valeur du jeton', () => {
  assert.equal(JSON.stringify(annex()).includes(TOKEN), false);
  assert.equal(JSON.stringify(classify({ fcmToken: `${TOKEN}-b` })).includes(TOKEN), false);
});
