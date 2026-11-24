'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { allocate, buildProposal, captureHandoverPoint, haversineM } = require('../earningsSettlement');

// Trajet rectiligne sud -> nord (~11,1 km par 0,1°) : pickup 6.70, destination 6.80.
const PICK = { lat: 6.70, lng: -3.49 };
const DEST = { lat: 6.80, lng: -3.49 };
const at = (lat) => ({ lat, lng: -3.49 });
const handover = (lat, extra = {}) => ({
  trusted: true, point: at(lat), ...extra,
});

function order(extra = {}) {
  return {
    budget: 1000, latitude: PICK.lat, longitude: PICK.lng, destLat: DEST.lat, destLng: DEST.lng,
    commissionStatus: 'charged', commissionPayerId: 'dA', commissionAmount: 200,
    pickedUpAt: 1, deliveryPhoto: 'photo.jpg', driverId: 'dB',
    driverHistory: [{ driverId: 'dA', phase: 'after_pickup', transferId: 't1', endedAtMs: 10, handover: handover(6.74) }],
    ...extra,
  };
}

test('allocate : somme exacte, plus fort reste, déterministe', () => {
  assert.deepEqual(allocate(800, [4, 6]), [320, 480]);
  assert.deepEqual(allocate(100, [1, 1, 1]), [34, 33, 33]);
  assert.equal(allocate(101, [3, 3, 3]).reduce((a, b) => a + b, 0), 101);
  assert.equal(allocate(0, [5, 5]).join(), '0,0');
  assert.equal(allocate(500, [0, 0]), null);
  for (let n = 0; n < 200; n++) {
    const ws = Array.from({ length: 1 + (n % 4) }, (_, i) => 1 + ((n * 7 + i * 13) % 97));
    assert.equal(allocate(n * 13, ws).reduce((a, b) => a + b, 0), n * 13);
  }
});

test('partage 40/60 selon les distances utiles : A 320, B 480, AZ 200 (A remboursé de sa commission)', () => {
  // A parcourt 4 des 10 km (jusqu’à 6.74), B les 6 autres.
  const p = buildProposal(order(), { deliveredAtMs: 1000 });
  assert.equal(p.needsReview, false);
  assert.equal(p.distributable, 800);
  const [a, b] = p.shares;
  assert.deepEqual([a.driverId, b.driverId], ['dA', 'dB']);
  assert.ok(Math.abs(a.share - 320) <= 1 && Math.abs(b.share - 480) <= 1);
  assert.equal(a.share + b.share, 800);
  // total versé = prix payé ; A reçoit sa part + la commission qu’il a avancée
  assert.equal(p.credits.dA + p.credits.dB, 1000);
  assert.equal(p.credits.dA, a.share + 200);
  assert.equal(p.credits.dB, b.share);
  assert.equal(p.algorithm, 'progress_toward_destination_v1');
  assert.equal(p.dueAtMs, 1000 + 24 * 3600 * 1000);
});

test('plusieurs transferts successifs : 3 livreurs, somme exacte', () => {
  const o = order({
    driverId: 'dC',
    driverHistory: [
      { driverId: 'dA', phase: 'after_pickup', transferId: 't1', endedAtMs: 10, handover: handover(6.73) },
      { driverId: 'dB', phase: 'after_pickup', transferId: 't2', endedAtMs: 20, handover: handover(6.76) },
    ],
  });
  const p = buildProposal(o, { deliveredAtMs: 0 });
  assert.equal(p.needsReview, false);
  assert.equal(p.shares.length, 3);
  assert.equal(p.shares.reduce((s, x) => s + x.share, 0), 800);
  assert.equal(Object.values(p.credits).reduce((a, b) => a + b, 0), 1000);
  assert.ok(p.shares[2].share > p.shares[0].share); // C : 4 km contre 3 km pour A
});

test('détour non rémunéré : un recul ne rapporte rien et déclenche la revue', () => {
  // Remise en arrière du point de départ (6.69) : A n’a fait aucun progrès.
  const p = buildProposal(order({
    driverHistory: [{ driverId: 'dA', phase: 'after_pickup', transferId: 't1', endedAtMs: 10, handover: handover(6.69) }],
  }), { deliveredAtMs: 0 });
  assert.equal(p.legs[0].usefulM, 0);
  assert.equal(p.needsReview, true);
  assert.ok(p.reasons.includes('zero_useful_distance'));
  assert.equal(p.shares, null);
  assert.equal(p.credits, null);
});

test('GPS manquant ou non fiable : aucune part inventée, validation administrative', () => {
  const missing = buildProposal(order({
    driverHistory: [{ driverId: 'dA', phase: 'after_pickup', transferId: 't1', endedAtMs: 10 }],
  }), { deliveredAtMs: 0 });
  assert.equal(missing.needsReview, true);
  assert.equal(missing.shares, null);
  assert.ok(missing.reasons.some((r) => r.startsWith('handover_gps_untrusted')));
  const untrusted = buildProposal(order({
    driverHistory: [{ driverId: 'dA', phase: 'after_pickup', transferId: 't1', endedAtMs: 10, handover: { trusted: false, point: at(6.74) } }],
  }), { deliveredAtMs: 0 });
  assert.equal(untrusted.shares, null);
  const noDest = buildProposal(order({ destLat: undefined }), { deliveredAtMs: 0 });
  assert.ok(noDest.reasons.includes('destination_coordinates_missing'));
  assert.equal(noDest.shares, null);
});

test('GPS incohérent : livreurs trop éloignés ou position périmée à la remise', () => {
  const now = 1_000_000;
  const ok = captureHandoverPoint({ lat: 6.74, lng: -3.49, updatedAtMs: now - 1000 }, { lat: 6.7401, lng: -3.49, updatedAtMs: now - 2000 }, now);
  assert.equal(ok.trusted, true);
  assert.ok(ok.separationM < 50);
  const far = captureHandoverPoint({ lat: 6.74, lng: -3.49, updatedAtMs: now }, { lat: 6.75, lng: -3.49, updatedAtMs: now }, now);
  assert.equal(far.trusted, false);
  assert.ok(far.reasons.includes('gps_drivers_too_far_apart'));
  assert.equal(far.point, null);
  const stale = captureHandoverPoint({ lat: 6.74, lng: -3.49, updatedAtMs: now - 10 * 60000 }, { lat: 6.74, lng: -3.49, updatedAtMs: now }, now);
  assert.equal(stale.trusted, false);
  const none = captureHandoverPoint(null, { lat: 0, lng: 0, updatedAtMs: now }, now);
  assert.equal(none.trusted, false);
  assert.ok(haversineM(at(6.7), at(6.8)) > 11000);
});

test('commission non tracée, preuve de remise ou de livraison absente : revue obligatoire', () => {
  assert.ok(buildProposal(order({ commissionStatus: undefined }), { deliveredAtMs: 0 }).reasons.includes('commission_untraced'));
  assert.ok(buildProposal(order({ commissionPayerId: 'dZ' }), { deliveredAtMs: 0 }).reasons.includes('commission_payer_not_in_chain'));
  assert.ok(buildProposal(order({ deliveryPhoto: null }), { deliveredAtMs: 0 }).reasons.includes('delivery_proof_missing'));
  const noProof = buildProposal(order({
    driverHistory: [{ driverId: 'dA', phase: 'after_pickup', endedAtMs: 10, handover: handover(6.74) }],
  }), { deliveredAtMs: 0 });
  assert.ok(noProof.reasons.includes('handover_proof_missing'));
});

test('les livreurs libérés avant récupération ne sont pas rémunérés', () => {
  const o = order();
  o.driverHistory.unshift({ driverId: 'dOld', phase: 'before_pickup', endedAtMs: 1 });
  const p = buildProposal(o, { deliveredAtMs: 0 });
  assert.deepEqual(p.chain, ['dA', 'dB']);
  assert.equal(p.credits.dOld, undefined);
});
