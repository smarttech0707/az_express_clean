'use strict';

// Génère un google-services.json FACTICE (projet demo-az-express) pour l'APK de test sur émulateurs.
// Il remplace, pour ce build seulement, la configuration de production du plugin Google Services :
// sans lui, le plugin natif initialiserait Firebase avec les identifiants de production.
//
// Usage : node test-env/make-demo-google-services.js <fichier-de-sortie>

const fs = require('fs');
const path = require('path');

const out = process.argv[2];
if (!out) { console.error('Usage : node make-demo-google-services.js <sortie>'); process.exit(1); }
if (!/[\\/]android[\\/]app[\\/]src[\\/]debug[\\/]google-services\.json$/.test(path.resolve(out))) {
  console.error('Refus : la sortie doit être android/app/src/debug/google-services.json (jamais le fichier de production).');
  process.exit(1);
}

const config = {
  project_info: { project_number: '000000000000', project_id: 'demo-az-express', storage_bucket: 'demo-az-express.appspot.com' },
  client: [{
    client_info: {
      mobilesdk_app_id: '1:000000000000:android:0000000000000000',
      android_client_info: { package_name: 'com.azexpress.app.test' },
    },
    oauth_client: [],
    // Format exigé par firebase-installations (^A[\w-]{38}$), sinon tout appel de fonction échoue avant d'atteindre
    // l'émulateur. Chaîne synthétique, volontairement lisible : ne correspond à aucun projet réel.
    api_key: [{ current_key: 'AIzaSyDEMO-az-express-local-emulator-00' }],
    services: { appinvite_service: { other_platform_oauth_client: [] } },
  }],
  configuration_version: '1',
};
fs.mkdirSync(path.dirname(out), { recursive: true });
fs.writeFileSync(out, `${JSON.stringify(config, null, 2)}\n`);
console.log(`Configuration factice écrite : ${out}`);
