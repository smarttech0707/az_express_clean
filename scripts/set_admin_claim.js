/**
 * Script à usage unique — ajoute le custom claim { admin: true }
 * à un compte Firebase Auth.
 *
 * Prérequis :
 *   1. Node.js installé
 *   2. Clé de service téléchargée depuis Firebase Console
 *      (Paramètres du projet → Comptes de service → Générer une nouvelle clé privée)
 *   3. npm install firebase-admin
 *
 * Usage :
 *   node scripts/set_admin_claim.js
 */

const admin = require('firebase-admin');
const serviceAccount = require('./serviceAccountKey.json'); // ← place ta clé ici

admin.initializeApp({
  credential: admin.credential.cert(serviceAccount),
});

// ── Modifie l'email ci-dessous si nécessaire ──────────────────
const ADMIN_EMAIL = 'znm0905@gmail.com';

async function run() {
  try {
    const user = await admin.auth().getUserByEmail(ADMIN_EMAIL);
    await admin.auth().setCustomUserClaims(user.uid, { admin: true });
    console.log(`✅ Claim admin ajouté à ${ADMIN_EMAIL} (uid: ${user.uid})`);
    console.log('   Le compte peut maintenant se connecter via l\'app.');
  } catch (err) {
    if (err.code === 'auth/user-not-found') {
      console.error(`❌ Aucun utilisateur trouvé avec l'email : ${ADMIN_EMAIL}`);
      console.error('   Crée d\'abord le compte dans Firebase Console → Authentication.');
    } else {
      console.error('❌ Erreur :', err.message);
    }
  } finally {
    process.exit(0);
  }
}

run();
