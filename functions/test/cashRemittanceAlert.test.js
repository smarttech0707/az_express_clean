'use strict';

// Mission 7B-3B-C — alerte administrative sur les reversements cash v2 en retard (> 24 h). Alerte SEULE : aucune écriture
// sur la commande, aucun mouvement de wallet.

const test = require('node:test');
const assert = require('node:assert/strict');
const { scanOverdueCashRemittances, CASH_REMITTANCE_DELAY_MS, COLLECTION } = require('../stuckOrderAlerts');

const NOW = 1_800_000_000_000;
const silent = { log() {}, error() {} };

function setup(orders) {
  const alerts = new Map();
  const writes = [];
  const admins = [
    { data: () => ({ role: 'super', isActive: true, fcmToken: 'token-root-0000000' }) },
    { data: () => ({ role: 'sub', isActive: true, permissions: ['restaurants'], fcmToken: 'token-sub-other-000' }) },
  ];
  const db = {
    collection(name) {
      if (name === 'orders') {
        return {
          where(field, op, value) {
            assert.deepEqual([field, op], ['cashRemittance.status', 'in'], 'requête sur un seul champ, sans index composite');
            return {
              limit: () => ({
                get: async () => ({
                  docs: Object.entries(orders)
                    .filter(([, o]) => value.includes(o.cashRemittance?.status))
                    .map(([id, o]) => ({ id, data: () => o })),
                }),
              }),
            };
          },
          doc: () => { throw new Error('aucune écriture sur orders'); },
        };
      }
      if (name === 'admins') return { where: () => ({ get: async () => ({ docs: admins }) }) };
      if (name === COLLECTION) {
        return {
          doc: (id) => ({
            create: async (data) => {
              if (alerts.has(id)) throw new Error('ALREADY_EXISTS');
              alerts.set(id, data); writes.push(id);
            },
          }),
        };
      }
      throw new Error(`collection inattendue : ${name}`);
    },
  };
  const sent = []; const audits = [];
  const run = (nowMs = NOW) => scanOverdueCashRemittances({
    db, nowMs, logger: silent,
    sendToToken: async (token, title, body, data) => { sent.push({ token, title, body, data }); },
    logAudit: async (d) => { audits.push(d); },
  });
  return { run, alerts, sent, audits, writes };
}

const order = (status, deliveredAtMs, extra = {}) => ({
  amountsVersion: 2, status: 'delivered', paymentMethod: 'cash', sellerId: 'r1', driverId: 'dA',
  cashRemittance: { status, amountDue: 3500, deliveredAtMs }, ...extra,
});

test('alerte au-delà de 24 h seulement, une fois par commande, aux administrateurs autorisés', async () => {
  const t = setup({
    late: order('pending', NOW - CASH_REMITTANCE_DELAY_MS - 1000),
    lateDeclared: order('declared', NOW - 3 * CASH_REMITTANCE_DELAY_MS),
    recent: order('pending', NOW - CASH_REMITTANCE_DELAY_MS + 60_000),
    exactly: order('pending', NOW - CASH_REMITTANCE_DELAY_MS),
    confirmed: order('confirmed', 1),
    disputed: order('disputed', 1),
    resolved: order('resolved', 1),
  });
  const first = await t.run();
  assert.deepEqual([first.alerted, first.duplicates, first.errors], [2, 0, 0]);
  assert.deepEqual([...t.alerts.keys()].sort(), [
    `late_cash_remittance_${NOW - CASH_REMITTANCE_DELAY_MS - 1000}`,
    `lateDeclared_cash_remittance_${NOW - 3 * CASH_REMITTANCE_DELAY_MS}`,
  ].sort());
  assert.equal(t.sent.length, 2, 'un jeton autorisé (super-admin) par alerte ; le sous-admin sans permission est exclu');
  assert.ok(t.sent.every((s) => s.token === 'token-root-0000000' && s.data.type === 'cash_remittance_overdue'));
  assert.match(t.sent[0].body, /Aucune action automatique/);
  assert.equal(t.audits.length, 2);
  // Rejeu du scan : aucune seconde alerte.
  const second = await t.run(NOW);
  assert.deepEqual([second.alerted, second.duplicates], [0, 2]);
  assert.equal(t.sent.length, 2);
});

test('commande hors périmètre ignorée : non v2, non livrée, date absente', async () => {
  const t = setup({
    legacy: order('pending', 1, { amountsVersion: undefined }),
    notDelivered: order('pending', 1, { status: 'cancelled' }),
    noDate: order('pending', null),
  });
  const r = await t.run();
  assert.equal(r.alerted, 0);
  assert.equal(t.sent.length, 0);
});

test('erreur de lecture : résumé en erreur, aucune exception (le scheduler continue)', async () => {
  const db = { collection: () => ({ where: () => ({ limit: () => ({ get: async () => { throw new Error('index manquant'); } }) }) }) };
  const r = await scanOverdueCashRemittances({ db, sendToToken: async () => {}, logAudit: async () => {}, nowMs: NOW, logger: silent });
  assert.equal(r.errors, 1);
});
