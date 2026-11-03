'use strict';

// Rapport de rapprochement E-Kbine — LECTURE SEULE. N'écrit rien (aucun solde, aucun statut, aucun document).
//
//   node scripts/ekbineReconciliationReport.js --project <id> [--out rapport.json]
//
// Refuse de démarrer sans `--project` explicite : choisir le projet est une décision humaine (jamais d'identifiant
// par défaut, jamais la production sans autorisation). Les identifiants du compte viennent de l'environnement
// (ADC / émulateur) ; rien n'est lu ni affiché comme secret.
const fs = require('fs');
const admin = require('firebase-admin');
const { analyzeLegacyEkOrders } = require('../ekbineReconciliation');

const arg = (name) => { const i = process.argv.indexOf(name); return i > 0 ? process.argv[i + 1] : undefined; };

async function main() {
  const projectId = arg('--project');
  if (!projectId) {
    console.error('Usage : node scripts/ekbineReconciliationReport.js --project <id> [--out fichier.json]');
    process.exit(2);
  }
  admin.initializeApp({ projectId });
  const db = admin.firestore();

  const orders = (await db.collection('ekbine_orders').get()).docs.map((d) => ({ id: d.id, ...d.data() }));
  const debits = (await db.collection('wallet_transactions').where('type', '==', 'ekbine_payment').get()).docs
    .map((d) => ({ id: d.id, ...d.data() }));
  const credited = (await db.collection('audit_logs').where('action', '==', 'ekbine_confirm_order').get()).docs
    .map((d) => d.data().targetId).filter(Boolean);
  // Remboursements éventuels déjà écrits dans les journaux clients (liés à une commande E-Kbine).
  const refundLedger = [];
  const clientIds = [...new Set(orders.map((o) => o.clientId).filter(Boolean))];
  for (const uid of clientIds) {
    const snap = await db.collection(`clients/${uid}/wallet_transactions`).where('type', '==', 'refund').get();
    snap.docs.forEach((d) => refundLedger.push({ orderId: d.data().orderId }));
  }

  const report = analyzeLegacyEkOrders({ orders, debits, creditedOrderIds: credited, refundLedger });
  const out = arg('--out');
  if (out) fs.writeFileSync(out, JSON.stringify(report, null, 2));
  console.log(JSON.stringify(report.summary, null, 2));
  if (!out) console.log('(ajoutez --out rapport.json pour le détail par commande)');
}

main().catch((e) => { console.error(e.message); process.exit(1); });
