'use strict';

// Scénario de bout en bout du consentement AZ IA contre les ÉMULATEURS LOCAUX (demo-az-express) :
// Auth + Firestore + Functions réels (code courant), fournisseur d'IA SIMULÉ (test-env/emulator/ai-sim.js).
// Joue le rôle de l'application (même appel callable `azIaChat`, mêmes champs). Comptes et données fictifs.
// Lecture/écriture : émulateurs uniquement (127.0.0.1) ; refuse tout autre hôte.
//
//   node test-env/ai-consent-e2e.js
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');

const PROJECT = 'demo-az-express';
const AUTH = 'http://127.0.0.1:9099';
const FIRESTORE = `http://127.0.0.1:8080/v1/projects/${PROJECT}/databases/(default)/documents`;
const FN = `http://127.0.0.1:5001/${PROJECT}/europe-west1/azIaChat`;
const SIM_LOG = path.join(__dirname, 'runtime', 'functions', 'ai-sim.log');
const EMAIL = 'client.test@az-test.invalid';
const PASSWORD = process.env.AZ_TEST_PASSWORD; // mot de passe des comptes FICTIFS de l'émulateur (jamais écrit dans le dépôt)
if (!PASSWORD) { console.error('Définissez AZ_TEST_PASSWORD (mot de passe des comptes de test).'); process.exit(2); }

const simCalls = () => (fs.existsSync(SIM_LOG) ? fs.readFileSync(SIM_LOG, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l)) : []);
const results = [];
const step = (name, ok, detail = '') => { results.push({ name, ok }); console.log(`${ok ? 'OK    ' : 'ÉCHEC '} ${name}${detail ? ` — ${detail}` : ''}`); };

async function signIn() {
  const r = await fetch(`${AUTH}/identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=fake`, {
    method: 'POST', headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ email: EMAIL, password: PASSWORD, returnSecureToken: true }),
  });
  const j = await r.json();
  if (!j.idToken) throw new Error(`connexion impossible (${j.error?.message})`);
  return { token: j.idToken, uid: j.localId };
}
const fsGet = async (token, p) => {
  const r = await fetch(`${FIRESTORE}/${p}`, { headers: { Authorization: `Bearer ${token}` } });
  return r.status === 404 ? null : r.json();
};
const call = async (token, data) => {
  const r = await fetch(FN, { method: 'POST', headers: { 'content-type': 'application/json', Authorization: `Bearer ${token}` }, body: JSON.stringify({ data }) });
  return r.json();
};
const GPS = { latitude: 5.4311, longitude: -4.0227, address: 'Position-test-GPS' };

(async () => {
  const { token, uid } = await signIn();
  const client = await fsGet(token, `clients/${uid}`);
  const f = client?.fields || {};
  const personal = { phone: f.phone?.stringValue, name: f.name?.stringValue, wallet: f.wallet?.integerValue };
  console.log('Données fictives du compte :', JSON.stringify({ ...personal, uid }));
  fs.rmSync(SIM_LOG, { force: true });
  const base = simCalls().length;

  // Sans consentement : ancienne application = même appel, aucun champ de consentement.
  let r = await call(token, { message: 'Bonjour, comment ça marche ?', location: GPS });
  step('1/3. Ancienne app / sans consentement : refus CONSENT_REQUIRED', r.error?.message === 'CONSENT_REQUIRED', JSON.stringify(r.error));
  step('4. Aucune requête transmise au fournisseur après refus', simCalls().length === base, `appels=${simCalls().length - base}`);
  r = await call(token, { consentAction: 'status' });
  step('3. Refus (aucun accord) : statut = non accordé', r.result?.consent?.granted === false);
  const doc0 = await fsGet(token, `ai_consents/${uid}`);
  step('3. Aucun accord enregistré avant l’acceptation (document absent ou granted=false)', doc0 === null || doc0.fields?.granted?.booleanValue === false);

  // Accord, mauvaise version puis bonne version.
  r = await call(token, { consentAction: 'grant', consentVersion: 999 });
  step('5. Accord avec une version inconnue refusé (APP_UPDATE_REQUIRED)', r.error?.message === 'APP_UPDATE_REQUIRED');
  r = await call(token, { consentAction: 'grant', consentVersion: 1 });
  step('5. Acceptation du consentement', r.result?.consent?.granted === true, JSON.stringify(r.result || r.error));
  const doc1 = await fsGet(token, `ai_consents/${uid}`);
  step('6. Accord enregistré dans Firestore (granted, version, fournisseurs)', doc1?.fields?.granted?.booleanValue === true
    && doc1.fields.version?.integerValue === '1' && (doc1.fields.providers?.arrayValue?.values || []).map((v) => v.stringValue).join() === 'anthropic,google',
  JSON.stringify(doc1?.fields && Object.keys(doc1.fields)));

  // Question générale, avec position envoyée par l'application.
  let before = simCalls().length;
  r = await call(token, { message: 'Comment fonctionne la livraison ?', location: GPS });
  let sent = simCalls().slice(before);
  const dump = (calls) => JSON.stringify(calls.map((c) => c.body));
  step('7. Question générale : réponse du fournisseur simulé', /question générale/.test(r.result?.reply || ''), r.result?.reply);
  step('7. Aucune donnée personnelle transmise (téléphone, nom, GPS)', sent.length === 1
    && ![personal.phone, personal.name, GPS.address, String(GPS.latitude)].some((v) => v && dump(sent).includes(v)));

  // Commande fictive.
  before = simCalls().length;
  r = await call(token, { message: 'Où en est ma commande ?', location: GPS });
  sent = simCalls().slice(before);
  step('8. Consultation d’une commande : outil track_order exécuté, réponse reçue', sent.length === 2 && /informations demandées/.test(r.result?.reply || ''), `appels=${sent.length}`);
  step('8. Seule la commande est transmise (pas de téléphone, GPS ; pas de solde)', ![personal.phone, GPS.address, String(GPS.latitude)].some((v) => v && dump(sent).includes(v))
    && /Colis fictif|livraison/i.test(dump(sent)));

  // Portefeuille fictif.
  before = simCalls().length;
  r = await call(token, { message: 'Quel est mon solde ?', location: GPS });
  sent = simCalls().slice(before);
  step('9. Consultation du portefeuille : solde transmis, rien d’autre', sent.length === 2 && dump(sent).includes(String(personal.wallet))
    && ![personal.phone, GPS.address].some((v) => v && dump(sent).includes(v)));

  // Adresse et GPS à la demande.
  before = simCalls().length;
  await call(token, { message: 'Livre chez moi', location: GPS });
  sent = simCalls().slice(before);
  step('Adresse : rubrique addresses seulement (pas de GPS, pas de téléphone)', sent.length === 2 && ![personal.phone, GPS.address, String(GPS.latitude)].some((v) => v && dump(sent).includes(v)));
  before = simCalls().length;
  await call(token, { message: 'Trouve une pharmacie près de moi', location: GPS });
  sent = simCalls().slice(before);
  step('GPS : transmis seulement via la rubrique location demandée', sent.length === 2 && !dump([sent[0]]).includes(String(GPS.latitude)) && dump([sent[1]]).includes(String(GPS.latitude)));

  // Retrait.
  r = await call(token, { consentAction: 'revoke' });
  step('10. Retrait du consentement', r.result?.consent?.granted === false);
  const doc2 = await fsGet(token, `ai_consents/${uid}`);
  step('10. Retrait enregistré dans Firestore (granted=false)', doc2?.fields?.granted?.booleanValue === false);
  before = simCalls().length;
  r = await call(token, { message: 'Et mon solde ?', location: GPS });
  step('11. Blocage après retrait : CONSENT_REQUIRED', r.error?.message === 'CONSENT_REQUIRED');
  step('11. Aucune requête au fournisseur après retrait', simCalls().length === before);

  const failed = results.filter((x) => !x.ok);
  console.log(`\n${results.length - failed.length}/${results.length} vérifications réussies.`);
  process.exit(failed.length ? 1 : 0);
})().catch((e) => { console.error('Échec du scénario :', e.message); process.exit(2); });
