'use strict';
// Aides communes aux tests M1.1 (émulateurs locaux uniquement : Auth 29199, Firestore 29080, Functions 29501).
const crypto = require('node:crypto');
const path = require('node:path');
const { createRequire } = require('node:module');
const req = createRequire(path.join(__dirname, '..', '..', 'functions', 'package.json'));

const PROJECT = 'demo-m1-feasibility';
const AUTH_HOST = '127.0.0.1:29199';
const FS_HOST = '127.0.0.1:29080';
const FN_HOST = '127.0.0.1:29501';
const KEY = 'fake-api-key';

delete process.env.GOOGLE_APPLICATION_CREDENTIALS;
process.env.FIREBASE_AUTH_EMULATOR_HOST = AUTH_HOST;
process.env.GCLOUD_PROJECT = PROJECT;
const admin = req('firebase-admin');
if (!admin.apps.length) admin.initializeApp({ projectId: PROJECT });
const auth = admin.auth();

const pw = () => `Pw-${crypto.randomBytes(8).toString('hex')}`; // jamais journalisé
const decodePart = (jwt, i) => JSON.parse(Buffer.from(jwt.split('.')[i], 'base64url').toString());

async function post(url, body, headers = {}) {
  const res = await fetch(url, { method: 'POST', headers: { 'content-type': 'application/json', ...headers }, body: JSON.stringify(body) });
  return { status: res.status, body: await res.json().catch(() => ({})) };
}

const idt = `http://${AUTH_HOST}/identitytoolkit.googleapis.com/v1`;
const exchange = (customToken) => post(`${idt}/accounts:signInWithCustomToken?key=${KEY}`, { token: customToken, returnSecureToken: true });
const signUpAnonymous = () => post(`${idt}/accounts:signUp?key=${KEY}`, { returnSecureToken: true });

/** Appel d'une callable de l'émulateur Functions (protocole HTTP des callables). */
function callable(name, data, idToken) {
  return post(`http://${FN_HOST}/${PROJECT}/europe-west1/${name}`, { data }, idToken ? { authorization: `Bearer ${idToken}` } : {});
}

const FS_ROOT = `http://${FS_HOST}/v1/projects/${PROJECT}/databases/(default)/documents`;
const toValue = (v) => (typeof v === 'string' ? { stringValue: v } : typeof v === 'boolean' ? { booleanValue: v }
  : Number.isInteger(v) ? { integerValue: String(v) } : { doubleValue: v });
const toFields = (o) => Object.fromEntries(Object.entries(o).map(([k, v]) => [k, toValue(v)]));

/** Accès Firestore REST avec un ID token (règles évaluées). token === 'owner' : contournement des règles (amorçage). */
async function fsReq(method, docPath, token, data, mask) {
  const q = mask ? '?' + mask.map((m) => `updateMask.fieldPaths=${m}`).join('&') : '';
  const res = await fetch(`${FS_ROOT}/${docPath}${q}`, {
    method,
    headers: { 'content-type': 'application/json', authorization: `Bearer ${token}` },
    body: data ? JSON.stringify({ fields: toFields(data) }) : undefined,
  });
  return res.status;
}
const fsGet = (p, t) => fsReq('GET', p, t);
const fsSet = (p, t, d) => fsReq('PATCH', p, t, d);                 // création ou remplacement
const fsUpdate = (p, t, d) => fsReq('PATCH', p, t, d, Object.keys(d)); // mise à jour de champs
const fsSeed = (p, d) => fsSet(p, 'owner', d);

async function resetEmulators() {
  await fetch(`http://${AUTH_HOST}/emulator/v1/projects/${PROJECT}/accounts`, { method: 'DELETE' });
  await fetch(`http://${FS_HOST}/emulator/v1/projects/${PROJECT}/databases/(default)/documents`, { method: 'DELETE' });
}

module.exports = {
  admin, auth, pw, decodePart, post, exchange, signUpAnonymous, callable, fsGet, fsSet, fsUpdate, fsSeed, resetEmulators,
  PROJECT, AUTH_HOST, FS_HOST, FN_HOST, KEY,
};
