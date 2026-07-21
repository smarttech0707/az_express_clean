'use strict';

const { AggregateField } = require('firebase-admin/firestore');

// Moteur de conciliation du wallet — trouvaille du Master Prompt 28 : aucun
// mécanisme ne vérifiait que la somme des `wallet_transactions` d'un compte
// correspond à son champ `wallet` actuel. Diagnostic en lecture seule
// uniquement — ne modifie jamais un solde, ne fait que signaler un écart.
//
// Portée volontairement limitée aux collections qui partagent le schéma
// standard `wallet` (champ) + `wallet_transactions` (sous-collection) :
// clients, livreurs, sellers, restaurants, pharmacies, boulangeries.
// `ekbine_agents` utilise un schéma différent (`walletBalance`, pas la même
// convention de sous-collection confirmée) — hors périmètre ici, chantier
// séparé si un jour voulu.
//
// Utilise les requêtes d'agrégation Firestore (`sum()`/`count()`) plutôt que
// de télécharger chaque transaction — un compte avec des milliers de
// transactions ne coûte qu'une poignée de lectures agrégées, pas une lecture
// par document (cohérent avec la culture de sobriété Firestore déjà actée
// dans ce projet, section Performance de CLAUDE.md).
//
// Vocabulaire `type` connu, classé une seule fois ici plutôt que deviné à la
// volée — toute transaction dont le type n'est dans AUCUNE des deux listes
// est explicitly comptée à part (`unclassifiedCount`) et n'entre PAS dans le
// solde recalculé, pour ne jamais produire un faux positif silencieux basé
// sur une classification incorrecte.
const CREDIT_TYPES = ['recharge', 'refund', 'earning', 'sale', 'credit'];
const DEBIT_TYPES  = ['withdrawal', 'payment', 'commission', 'debit', 'purchase'];

const WALLET_COLLECTIONS = ['clients', 'livreurs', 'sellers', 'restaurants', 'pharmacies', 'boulangeries'];

async function sumAmount(db, collectionPath, types) {
  const snap = await db.collection(collectionPath)
    .where('type', 'in', types)
    .aggregate({ total: AggregateField.sum('amount') })
    .get();
  return Number(snap.data().total || 0);
}

async function countUnclassified(db, collectionPath, knownTypes) {
  const snap = await db.collection(collectionPath)
    .where('type', 'not-in', knownTypes)
    .count()
    .get();
  return snap.data().count || 0;
}

// Concilie un seul compte : recalcule le solde attendu à partir de
// wallet_transactions et le compare au champ `wallet` actuel du document.
async function reconcileAccount(db, collectionName, docSnap) {
  const docId  = docSnap.id;
  const wallet = Number(docSnap.data().wallet || 0);
  const txPath = `${collectionName}/${docId}/wallet_transactions`;

  const [credits, debits, unclassifiedCount] = await Promise.all([
    sumAmount(db, txPath, CREDIT_TYPES),
    sumAmount(db, txPath, DEBIT_TYPES),
    countUnclassified(db, txPath, [...CREDIT_TYPES, ...DEBIT_TYPES]),
  ]);

  const computedBalance = credits - debits;
  const drift = wallet - computedBalance;

  return { collection: collectionName, docId, wallet, computedBalance, drift, unclassifiedCount };
}

// Parcourt les comptes d'une collection et retourne uniquement ceux avec un
// écart réel ou des transactions non classées (pas d'écriture pour les
// comptes propres — évite de faire grossir la collection de résultats pour rien).
async function reconcileCollection(db, collectionName) {
  const snap = await db.collection(collectionName).get();
  const findings = [];
  for (const docSnap of snap.docs) {
    const result = await reconcileAccount(db, collectionName, docSnap);
    if (result.drift !== 0 || result.unclassifiedCount > 0) {
      findings.push(result);
    }
  }
  return { checked: snap.size, findings };
}

async function runWalletReconciliation(db, admin, { logAudit } = {}) {
  const allFindings = [];
  let totalChecked = 0;

  for (const collectionName of WALLET_COLLECTIONS) {
    const { checked, findings } = await reconcileCollection(db, collectionName);
    totalChecked += checked;
    allFindings.push(...findings);
  }

  if (allFindings.length > 0) {
    const batch = db.batch();
    const runId = `run_${Date.now()}`;
    allFindings.forEach((f) => {
      const ref = db.collection('wallet_reconciliation_findings').doc();
      batch.set(ref, { ...f, runId, checkedAt: admin.firestore.FieldValue.serverTimestamp() });
    });
    await batch.commit();
  }

  if (logAudit) {
    await logAudit({
      userType: 'system', action: 'wallet_reconciliation_run', status: 'success',
      metadata: { totalChecked, findingsCount: allFindings.length },
    });
  }

  return { totalChecked, findingsCount: allFindings.length };
}

function buildWalletReconciliationCheck({ db, admin, onSchedule, logAudit }) {
  return onSchedule({
    schedule:       'every monday 04:00',
    timeZone:       'Africa/Abidjan',
    timeoutSeconds: 300,
    memory:         '256MiB',
    // Master Prompt 122 — quota CPU Cloud Run régional : scheduler
    // hebdomadaire en lecture seule (diagnostic, aucune écriture wallet
    // réelle), une seule instance nécessaire.
    maxInstances:   1,
    cpu:            0.5,
  }, async () => {
    try {
      const result = await runWalletReconciliation(db, admin, { logAudit });
      if (result.findingsCount > 0) {
        console.warn(`⚠️ Conciliation wallet : ${result.findingsCount} écart(s) détecté(s) sur ${result.totalChecked} comptes vérifiés.`);
      }
    } catch (err) {
      console.error('walletReconciliationCheck error:', err.message);
    }
  });
}

module.exports = {
  runWalletReconciliation,
  reconcileAccount,
  reconcileCollection,
  buildWalletReconciliationCheck,
  CREDIT_TYPES,
  DEBIT_TYPES,
  WALLET_COLLECTIONS,
};
