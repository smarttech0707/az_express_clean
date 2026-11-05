'use strict';

// Banc d'essai des notifications (Mission 7E-30), exécuté dans un processus enfant : charge le VRAI index.js avec un Firestore et un
// Firebase Messaging factices. Aucun accès réseau, aucun envoi FCM réel. Entrée : JSON en argv[2] ; sortie : '@@' + JSON.
const spec = JSON.parse(process.argv[2]);
Object.assign(process.env, spec.env);
const admin = require('firebase-admin');

const sends = [];
const dedupe = new Set();
const data = spec.data || {};
const col = (name) => ({
  doc: (id) => ({
    get: async () => ({ exists: !!(data[name] || {})[id], data: () => (data[name] || {})[id] }),
    create: async () => {
      const key = `${name}/${id}`;
      if (dedupe.has(key)) throw Object.assign(new Error('ALREADY_EXISTS'), { code: 6 });
      dedupe.add(key);
    },
    collection: () => col('_sub'),
  }),
  where: (field, op, value) => ({
    limit: () => ({
      get: async () => {
        const docs = Object.entries(data[name] || {}).filter(([, d]) => d[field] === value).map(([id, d]) => ({ id, data: () => d }));
        return { docs, empty: !docs.length };
      },
    }),
    get: async () => ({ docs: [], empty: true }),
  }),
  add: async () => ({}),
});
const fakeDb = { collection: col, runTransaction: async () => ({}) };
const realFirestore = admin.firestore;
Object.defineProperty(admin, 'firestore', { value: Object.assign(() => fakeDb, realFirestore), configurable: true });
const messaging = {
  send: async (m) => { sends.push({ kind: 'send', token: m.token }); return 'id'; },
  sendEachForMulticast: async (m) => { sends.push({ kind: 'multi', tokens: m.tokens }); return { responses: m.tokens.map(() => ({ success: true })) }; },
};
Object.defineProperty(admin, 'messaging', { value: () => messaging, configurable: true });

(async () => {
  const m = require('./../index.js');
  for (const call of spec.calls) {
    const event = { id: call.eventId, params: { orderId: call.orderId || 'o1' }, data: call.update
      ? { before: { data: () => call.before }, after: { data: () => call.after } }
      : { data: () => call.order } };
    await m[call.fn].run(event);
  }
  process.stdout.write('@@' + JSON.stringify({ sends, dedupe: [...dedupe] }));
  process.exit(0);
})().catch((e) => { process.stderr.write(String(e && e.stack)); process.exit(1); });
