'use strict';

// LECTURE SEULE. Mesure l'usage des anciennes versions de l'application livreur
// avant la fermeture de la règle Firestore `assigned -> accepted`.
//
// Une course acceptée par l'acceptation directe (ancienne version) n'a pas de
// `commissionStatus` : acceptOrderCF le pose toujours. Fermer la règle seulement
// quand ce nombre reste nul sur la période choisie.
//
// Usage (jamais lancé automatiquement) :
//   node functions/scripts/legacyAcceptanceReport.js --project <id> [--days 14]
// Nécessite des identifiants Admin explicites ; n'écrit rien.
const admin = require('firebase-admin');

async function main() {
  const args = process.argv.slice(2);
  const arg = (name, fallback) => {
    const i = args.indexOf(`--${name}`);
    return i >= 0 ? args[i + 1] : fallback;
  };
  const project = arg('project');
  if (!project) throw new Error('--project est obligatoire (aucun projet par défaut)');
  const days = Number(arg('days', 14));
  admin.initializeApp({ projectId: project });
  const since = admin.firestore.Timestamp.fromMillis(Date.now() - days * 86400000);
  const snap = await admin.firestore().collection('orders')
    .where('createdAt', '>=', since).orderBy('createdAt', 'desc').limit(5000).get();
  let accepted = 0; let legacy = 0;
  const legacyDrivers = new Set();
  snap.docs.forEach((doc) => {
    const o = doc.data();
    if (!['accepted', 'picked_up', 'delivered'].includes(o.status) || !o.driverId) return;
    accepted++;
    if (!o.commissionStatus) { legacy++; legacyDrivers.add(o.driverId); }
  });
  console.log(JSON.stringify({
    project, days, scanned: snap.size, accepted, acceptedByLegacyApp: legacy,
    distinctLegacyDrivers: legacyDrivers.size, truncated: snap.size >= 5000,
    safeToClose: legacy === 0 && snap.size < 5000,
  }, null, 2));
}

main().catch((e) => { console.error(e.message); process.exit(1); });
