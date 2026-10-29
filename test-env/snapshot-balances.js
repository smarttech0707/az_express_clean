'use strict';
// Relevé LECTURE SEULE des soldes, stocks et écritures dans l'ÉMULATEUR Firestore
// (127.0.0.1:8080, projet demo-az-express). Refuse toute autre cible : aucune
// lecture de la production n'est possible avec cet outil.
//
//   node test-env/snapshot-balances.js avant      -> écrit test-env/.snapshots/avant.json
//   node test-env/snapshot-balances.js apres      -> relève, puis affiche les DIFFÉRENCES avec « avant »
//   node test-env/snapshot-balances.js apres avant -> compare « apres » à « avant » (noms libres)
const fs = require('node:fs');
const path = require('node:path');

const HOST = '127.0.0.1:8080';
const PROJECT = 'demo-az-express';
const BASE = `http://${HOST}/v1/projects/${PROJECT}/databases/(default)/documents`;
const DIR = path.join(__dirname, '.snapshots');
const label = process.argv[2];
const against = process.argv[3] || (label === 'avant' ? null : 'avant');
if (!label) { console.error('Usage : node test-env/snapshot-balances.js <nom> [nom-de-comparaison]'); process.exit(2); }
if (process.env.FIRESTORE_EMULATOR_HOST && process.env.FIRESTORE_EMULATOR_HOST !== HOST) {
  console.error('Cible refusée : seul 127.0.0.1:8080 est autorisé.'); process.exit(2);
}

const plain = (v) => {
  if (v == null) return null;
  const [t, x] = Object.entries(v)[0];
  if (t === 'integerValue') return Number(x);
  if (t === 'mapValue') return Object.fromEntries(Object.entries(x.fields || {}).map(([k, y]) => [k, plain(y)]));
  if (t === 'arrayValue') return (x.values || []).map(plain);
  if (t === 'nullValue') return null;
  return x;
};
async function list(collectionPath) {
  const out = [];
  let token = '';
  do {
    const r = await fetch(`${BASE}/${collectionPath}?pageSize=300${token ? `&pageToken=${token}` : ''}`, {
      headers: { Authorization: 'Bearer owner' },
    });
    if (!r.ok) throw new Error(`${collectionPath} : HTTP ${r.status}`);
    const j = await r.json();
    for (const d of j.documents || []) out.push({ id: d.name.split('/').pop(), data: plain({ mapValue: { fields: d.fields || {} } }) });
    token = j.nextPageToken || '';
  } while (token);
  return out;
}

(async () => {
  const snap = { takenAt: new Date().toISOString(), wallets: {}, stocks: {}, orders: {}, boutiqueOrders: {}, walletTx: {}, audit: 0 };
  for (const col of ['clients', 'livreurs', 'sellers']) {
    for (const d of await list(col)) {
      snap.wallets[`${col}/${d.id}`] = { nom: d.data.name || d.data.identifiant || '', wallet: d.data.wallet ?? null };
      for (const t of await list(`${col}/${d.id}/wallet_transactions`)) {
        snap.walletTx[`${col}/${d.id}/${t.id}`] = { type: t.data.type, amount: t.data.amount, orderId: t.data.orderId || null };
      }
    }
  }
  for (const d of await list('boutique_products')) snap.stocks[d.id] = d.data.stock ?? null;
  for (const d of await list('orders')) {
    const o = d.data;
    snap.orders[d.id] = {
      status: o.status, type: o.type, paymentMethod: o.paymentMethod, isPaid: o.isPaid ?? null, budget: o.budget ?? null,
      totalAmount: o.totalAmount ?? null, driverId: o.driverId || null, commissionStatus: o.commissionStatus || null,
      commissionAmount: o.commissionAmount ?? null, hasSelfie: !!o.driverAcceptanceSelfie,
    };
  }
  for (const d of await list('boutique_orders')) snap.boutiqueOrders[d.id] = { status: d.data.status, totalAmount: d.data.totalAmount ?? null, qty: d.data.qty ?? null };
  snap.audit = (await list('audit_logs')).length;

  fs.mkdirSync(DIR, { recursive: true });
  fs.writeFileSync(path.join(DIR, `${label}.json`), JSON.stringify(snap, null, 2));
  console.log(`Relevé « ${label} » écrit (${Object.keys(snap.wallets).length} portefeuilles, ${Object.keys(snap.orders).length} commandes).`);
  if (!against) { for (const [k, v] of Object.entries(snap.wallets)) console.log(`  ${k.padEnd(48)} ${String(v.nom).padEnd(18)} ${v.wallet}`); return; }

  const prev = JSON.parse(fs.readFileSync(path.join(DIR, `${against}.json`), 'utf8'));
  console.log(`\nDIFFÉRENCES « ${against} » -> « ${label} »`);
  let n = 0;
  const show = (s) => { n += 1; console.log('  ' + s); };
  for (const k of new Set([...Object.keys(prev.wallets), ...Object.keys(snap.wallets)])) {
    const a = prev.wallets[k]?.wallet, b = snap.wallets[k]?.wallet;
    if (a !== b) show(`SOLDE ${k} (${snap.wallets[k]?.nom || prev.wallets[k]?.nom}) : ${a} -> ${b}  (${typeof a === 'number' && typeof b === 'number' ? (b - a > 0 ? '+' : '') + (b - a) : 'n/a'})`);
  }
  for (const k of new Set([...Object.keys(prev.stocks), ...Object.keys(snap.stocks)])) {
    if (prev.stocks[k] !== snap.stocks[k]) show(`STOCK ${k} : ${prev.stocks[k]} -> ${snap.stocks[k]}`);
  }
  for (const k of Object.keys(snap.walletTx)) if (!prev.walletTx[k]) show(`ÉCRITURE ${k} : ${JSON.stringify(snap.walletTx[k])}`);
  for (const k of new Set([...Object.keys(prev.orders), ...Object.keys(snap.orders)])) {
    if (JSON.stringify(prev.orders[k]) !== JSON.stringify(snap.orders[k])) show(`COMMANDE ${k} : ${JSON.stringify(snap.orders[k])}`);
  }
  for (const k of new Set([...Object.keys(prev.boutiqueOrders), ...Object.keys(snap.boutiqueOrders)])) {
    if (JSON.stringify(prev.boutiqueOrders[k]) !== JSON.stringify(snap.boutiqueOrders[k])) show(`BOUTIQUE ${k} : ${JSON.stringify(snap.boutiqueOrders[k])}`);
  }
  if (snap.audit !== prev.audit) show(`audit_logs : ${prev.audit} -> ${snap.audit} (+${snap.audit - prev.audit})`);
  if (!n) console.log('  (aucune différence)');
})().catch((e) => { console.error('Échec :', e.message); process.exit(1); });
