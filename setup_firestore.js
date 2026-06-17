/**
 * Script d'initialisation Firestore — AZ Express
 * Usage: node setup_firestore.js
 */
const { initializeApp, cert } = require('firebase-admin/app');
const { getFirestore, FieldValue } = require('firebase-admin/firestore');
const { getAuth } = require('firebase-admin/auth');

// Utilise les credentials Firebase CLI (pas besoin de service account séparé)
const app = initializeApp({
  projectId: 'az-express-clean',
});

const db  = getFirestore(app);
const auth = getAuth(app);

async function setup() {
  console.log('🚀 Initialisation Firestore AZ Express...\n');

  // ── 1. CONFIG COMMISSION ─────────────────────────────────────────────────
  await db.collection('config').doc('commission').set({
    commissionBasic:    100,   // courses 500–1000 FCFA
    commissionStandard: 200,   // courses > 1000 FCFA
    threshold:          1000,  // montant seuil en FCFA
    updatedAt: new Date(),
  }, { merge: true });
  console.log('✅ config/commission créé (100 FCFA ≤1000 / 200 FCFA >1000)');

  // ── 2. CONFIG APP ────────────────────────────────────────────────────────
  await db.collection('config').doc('app').set({
    maintenanceMode: false,
    minAppVersion:   '1.0.0',
    feexpayMode:     'test',           // passer à 'live' en production
    supportPhone:    '+2250798051397',
    supportWhatsApp: '+2250798051397',
    whatsAppUrl:     'https://wa.me/2250798051397',
    updatedAt: new Date(),
  }, { merge: true });
  console.log('✅ config/app créé (WhatsApp: +2250798051397)');

  // ── 3. COMPTE ADMIN ──────────────────────────────────────────────────────
  const adminEmail    = 'znm0905@gmail.com';
  const adminPassword = 'Verges0748';

  let adminUid;
  try {
    const user = await auth.createUser({
      email:         adminEmail,
      password:      adminPassword,
      displayName:   'Admin AZ Express',
      emailVerified: true,
    });
    adminUid = user.uid;
    console.log(`✅ Compte admin créé : ${adminEmail}`);
  } catch (e) {
    if (e.code === 'auth/email-already-exists') {
      const user = await auth.getUserByEmail(adminEmail);
      adminUid = user.uid;
      console.log(`ℹ️  Admin existe déjà : ${adminEmail} (uid: ${adminUid})`);
    } else {
      throw e;
    }
  }

  // Créer le document admin dans Firestore
  await db.collection('admins').doc(adminUid).set({
    email: adminEmail,
    role:  'superadmin',
    createdAt: new Date(),
  }, { merge: true });
  console.log(`✅ Document admins/${adminUid} créé`);

  console.log('\n═══════════════════════════════════════');
  console.log('🎉 Initialisation terminée !');
  console.log('');
  console.log('📧 Email admin    :', adminEmail);
  console.log('🔑 Mot de passe   :', adminPassword);
  console.log('🆔 UID admin      :', adminUid);
  console.log('═══════════════════════════════════════');
  console.log('\nTu peux maintenant te connecter à l\'admin panel avec ces identifiants.');

  process.exit(0);
}

setup().catch(err => {
  console.error('❌ Erreur:', err.message);
  process.exit(1);
});
