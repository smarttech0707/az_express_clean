'use strict';

// Rapport de rapprochement Restaurant / Boulangerie — LECTURE SEULE. N'écrit rien (aucun solde, aucun statut, aucun
// remboursement, aucun document).
//
//   node scripts/partnerOrderReconciliationReport.js --plan
//       Affiche les requêtes exactes et le nombre maximal de lectures. NE SE CONNECTE À RIEN.
//   node scripts/partnerOrderReconciliationReport.js --project <id> [--out rapport.json] [--salt <texte>]
//                                                    [--max-reads 50000] [--raw]
//
// Refuse de démarrer sans `--project` explicite : choisir le projet est une décision humaine. Ne jamais l'exécuter
// contre la production sans autorisation écrite. Les identifiants du compte viennent de l'environnement (ADC /
// émulateur) ; rien n'est lu ni affiché comme secret. Seules des requêtes `get()` sont émises.
//
// Données personnelles : le rapport écrit par défaut est ANONYMISÉ (empreintes salées, montants, codes). `--raw`
// produit le détail avec les identifiants en clair : à réserver à un poste de confiance, jamais à partager.
const fs = require('fs');
const admin = require('firebase-admin');
const { analyzePartnerOrders, anonymizeReport } = require('../partnerOrderReconciliation');
const { PARTNER_SELLER_TYPES } = require('../partnerOrderAmounts');

const arg = (name) => { const i = process.argv.indexOf(name); return i > 0 ? process.argv[i + 1] : undefined; };
const flag = (name) => process.argv.includes(name);
const PARTNER_COLLECTION = { restaurant: 'restaurants', boulangerie: 'boulangeries' };
const PAGE_SIZE = 500;
const LEDGER_LINES_MAX = 20; // une commande n'a que quelques lignes de journal ; au-delà, c'est un constat en soi
const DEFAULT_MAX_READS = 50000;

const QUERIES = Object.freeze([
  "orders        where sellerType == 'restaurant' | 'boulangerie'  orderBy __name__, pages de 500",
  `clients/{clientId}/wallet_transactions      where orderId == {orderId}  limit ${LEDGER_LINES_MAX}`,
  `{restaurants|boulangeries}/{sellerId}/wallet_transactions  where orderId == {orderId}  limit ${LEDGER_LINES_MAX}`,
  `livreurs/{driverId}/wallet_transactions     where orderId == {orderId}  limit ${LEDGER_LINES_MAX}`,
]);

// Lectures facturées : 1 par document renvoyé, minimum 1 par requête.
class ReadBudget {
  constructor(max) { this.max = max; this.used = 0; }
  charge(n) {
    this.used += Math.max(1, n);
    if (this.used > this.max) { const e = new Error('READ_BUDGET_EXCEEDED'); e.code = 'READ_BUDGET_EXCEEDED'; throw e; }
  }
}

async function ledgerFor(db, path, orderId, budget) {
  const snap = await db.collection(path).where('orderId', '==', orderId).limit(LEDGER_LINES_MAX).get();
  budget.charge(snap.size);
  return snap.docs.map((d) => ({ orderId, type: d.data().type, amount: d.data().amount }));
}

async function readOrders(db, sellerType, budget) {
  const out = [];
  let last = null;
  for (;;) {
    let q = db.collection('orders').where('sellerType', '==', sellerType)
      .orderBy(admin.firestore.FieldPath.documentId()).limit(PAGE_SIZE);
    if (last) q = q.startAfter(last);
    const snap = await q.get();
    budget.charge(snap.size);
    snap.docs.forEach((d) => out.push({ id: d.id, ...d.data() }));
    if (snap.size < PAGE_SIZE) return out;
    last = snap.docs[snap.docs.length - 1];
  }
}

function printPlan(maxReads) {
  console.log('Requêtes émises (lecture seule, aucune écriture) :');
  QUERIES.forEach((q) => console.log(`  - ${q}`));
  console.log(`Plafond de lectures de ce lancement : ${maxReads} (arrêt immédiat au-delà).`);
  console.log('Pire cas : N commandes + au plus 3 requêtes de journal par commande (minimum 1 lecture chacune, jusqu\'à ' +
    `${LEDGER_LINES_MAX} documents chacune) ; en pratique ≈ N × (1 + 3 + lignes réelles).`);
}

async function main() {
  const maxReads = Number(arg('--max-reads')) > 0 ? Number(arg('--max-reads')) : DEFAULT_MAX_READS;
  if (flag('--plan')) { printPlan(maxReads); return; }
  const projectId = arg('--project');
  if (!projectId) {
    console.error('Usage : node scripts/partnerOrderReconciliationReport.js --plan | --project <id> [--out fichier.json] [--salt texte] [--max-reads n] [--raw]');
    process.exit(2);
  }
  admin.initializeApp({ projectId });
  const db = admin.firestore();
  const budget = new ReadBudget(maxReads);
  const errors = [];
  let incomplete = false;

  const orders = [];
  try {
    for (const sellerType of PARTNER_SELLER_TYPES) orders.push(...await readOrders(db, sellerType, budget));
  } catch (e) {
    // Sans la liste complète des commandes, aucun rapport fiable : on s'arrête.
    console.error(`Lecture des commandes interrompue (${e.code || 'ERREUR'}). Aucun rapport écrit.`);
    process.exit(1);
  }

  const clientLedger = [];
  const partnerLedger = [];
  const driverLedger = [];
  for (const o of orders) {
    try {
      if (o.clientId) clientLedger.push(...await ledgerFor(db, `clients/${o.clientId}/wallet_transactions`, o.id, budget));
      if (o.sellerId) partnerLedger.push(...await ledgerFor(db, `${PARTNER_COLLECTION[o.sellerType]}/${o.sellerId}/wallet_transactions`, o.id, budget));
      if (o.driverId) driverLedger.push(...await ledgerFor(db, `livreurs/${o.driverId}/wallet_transactions`, o.id, budget));
    } catch (e) {
      if (e.code === 'READ_BUDGET_EXCEEDED') { incomplete = true; errors.push({ type: 'READ_BUDGET_EXCEEDED' }); break; }
      // Une commande illisible n'arrête pas le rapport : elle est signalée, jamais ignorée en silence.
      incomplete = true;
      errors.push({ type: 'LEDGER_READ_FAILED', code: e.code || 'ERREUR' });
    }
  }

  const raw = analyzePartnerOrders({ orders, clientLedger, partnerLedger, driverLedger });
  const body = flag('--raw') ? raw : anonymizeReport(raw, arg('--salt'));
  const report = { ...body, run: { readsUsed: budget.used, maxReads, incomplete, errors, anonymized: !flag('--raw') } };
  const out = arg('--out');
  if (out) fs.writeFileSync(out, JSON.stringify(report, null, 2));
  console.log(JSON.stringify({ ...report.summary, run: report.run }, null, 2));
  if (!out) console.log('(ajoutez --out rapport.json pour le détail par commande)');
}

main().catch((e) => { console.error(e.code || 'ERREUR'); process.exit(1); });
