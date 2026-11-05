'use strict';

// Banc d'essai des notifications (Missions 7E-30/31), exécuté dans un processus enfant : charge le VRAI index.js avec un Firestore et un
// Firebase Messaging factices. Aucun accès réseau, aucun envoi FCM réel. Entrée : JSON en argv[2] ; sortie : '@@' + JSON.
//   spec.env, spec.data (collection -> id -> document), spec.calls [{ fn, eventId, update, before, after, order, parallel }],
//   spec.failCreate (la réservation Firestore échoue), spec.sendError (code FCM pour tous les envois),
//   spec.tokenErrors { token: code }, spec.run { fn: 'autoExpireOrders' } (planifiée), spec.now (Date.now figé).
const spec = JSON.parse(process.argv[2]);
Object.assign(process.env, spec.env);
if (spec.now) { const fixed = spec.now; Date.now = () => fixed; }
const admin = require('firebase-admin');

const sends = [];
const markers = { ...(spec.markers || {}) }; // notification_dedupe/<id> -> document
const data = spec.data || {};
const writes = [];
// JSON ne porte pas de fonctions : createdAtMs devient un horodatage minimal (toMillis/toDate/seconds).
for (const docs of Object.values(data)) {
  for (const d of Object.values(docs)) {
    if (typeof d.createdAtMs === 'number') {
      const ms = d.createdAtMs;
      d.createdAt = { toMillis: () => ms, toDate: () => new Date(ms), seconds: Math.floor(ms / 1000), nanoseconds: 0 };
    }
  }
}
const lowerBound = (v) => (v && typeof v.toMillis === 'function' ? v.toMillis() : v);

function matches(doc, filters) {
  return filters.every(({ field, op, value }) => {
    const v = doc[field];
    if (op === '==') return v === value;
    if (op === 'in') return value.includes(v);
    if (op === '<=') return v === undefined || lowerBound(v) <= lowerBound(value);
    if (op === '>=') return v === undefined || lowerBound(v) >= lowerBound(value);
    return true;
  });
}
function query(name, filters = []) {
  const q = {
    where: (field, op, value) => query(name, [...filters, { field, op, value }]),
    orderBy: () => q,
    limit: () => q,
    get: async () => {
      const docs = Object.entries(data[name] || {}).filter(([, d]) => matches(d, filters)).map(([id, d]) => snap(name, id, d));
      return { docs, empty: !docs.length, size: docs.length };
    },
  };
  return q;
}
const snap = (name, id, d) => ({ id, exists: d !== undefined, data: () => d, ref: docRef(name, id) });
function docRef(name, id) {
  const key = `${name}/${id}`;
  return {
    id, path: key, __col: name,
    get: async () => snap(name, id, name === 'notification_dedupe' ? markers[id] : (data[name] || {})[id]),
    create: async (doc) => {
      if (name !== 'notification_dedupe') { writes.push(key); return; }
      if (spec.failCreate) throw Object.assign(new Error('UNAVAILABLE'), { code: 14 });
      if (markers[id]) throw Object.assign(new Error('ALREADY_EXISTS'), { code: 6 });
      markers[id] = { ...doc };
    },
    update: async (patch) => { if (name === 'notification_dedupe') markers[id] = { ...markers[id], ...patch }; else writes.push(key); },
    set: async () => { writes.push(key); },
    collection: (sub) => collection(`${key}/${sub}`),
  };
}
function collection(name) {
  return { ...query(name), doc: (id) => docRef(name, id), add: async () => { writes.push(`${name}/+`); return { id: 'x' }; } };
}
const tx = {
  get: async (target) => (typeof target.get === 'function' && target.__col ? target.get() : target.get()),
  update: (ref) => { writes.push(ref.path); },
  set: (ref) => { writes.push(ref.path); },
  create: (ref) => { writes.push(ref.path); },
  delete: (ref) => { writes.push(ref.path); },
};
const fakeDb = { collection, runTransaction: async (cb) => cb(tx), batch: () => ({ set() {}, update() {}, commit: async () => {} }) };
const realFirestore = admin.firestore;
Object.defineProperty(admin, 'firestore', { value: Object.assign(() => fakeDb, realFirestore), configurable: true });
const fcmError = (code) => Object.assign(new Error(code), { code });
const messaging = {
  send: async (m) => {
    sends.push({ kind: 'send', token: m.token });
    const code = (spec.tokenErrors || {})[m.token] || spec.sendError;
    if (code) throw fcmError(code);
    return 'id';
  },
  sendEachForMulticast: async (m) => {
    sends.push({ kind: 'multi', tokens: m.tokens });
    if (spec.sendError) throw fcmError(spec.sendError);
    return { responses: m.tokens.map((t) => ((spec.tokenErrors || {})[t] ? { success: false, error: fcmError(spec.tokenErrors[t]) } : { success: true })) };
  },
};
Object.defineProperty(admin, 'messaging', { value: () => messaging, configurable: true });

(async () => {
  const m = require('./../index.js');
  const exec = async (call) => {
    const event = { id: call.eventId, params: { orderId: call.orderId || 'o1' }, data: call.update
      ? { before: { data: () => call.before }, after: { data: () => call.after } }
      : { data: () => call.order } };
    await m[call.fn].run(event);
  };
  const parallel = (spec.calls || []).filter((c) => c.parallel);
  for (const call of (spec.calls || []).filter((c) => !c.parallel)) await exec(call);
  if (parallel.length) await Promise.all(parallel.map(exec));
  if (spec.run) await m[spec.run.fn].run({ scheduleTime: new Date().toISOString() });
  process.stdout.write('@@' + JSON.stringify({ sends, markers, writes }));
  process.exit(0);
})().catch((e) => { process.stderr.write(String(e && e.stack)); process.exit(1); });
