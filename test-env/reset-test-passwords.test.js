'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  ALLOWED_PROJECT, ALLOWED_EMAILS,
  validateRequest, buildPlan, resetPasswords, main,
} = require('./reset-test-passwords');

const OK = { project: ALLOWED_PROJECT, confirmProject: ALLOWED_PROJECT, emails: [...ALLOWED_EMAILS] };

test('validateRequest : accepte le projet et les emails autorisés', () => {
  const { project, emails } = validateRequest(OK);
  assert.equal(project, ALLOWED_PROJECT);
  assert.deepEqual(emails, ALLOWED_EMAILS);
});

test('validateRequest : refuse la production, même nommée explicitement', () => {
  assert.throws(() => validateRequest({ ...OK, project: 'az-express-b0469', confirmProject: 'az-express-b0469' }), /PRODUCTION/);
  assert.throws(() => validateRequest({ ...OK, project: 'az-express-clean', confirmProject: 'az-express-clean' }), /PRODUCTION/);
});

test('validateRequest : refuse tout projet autre que az-express-preprod, même un nom "test" plausible', () => {
  assert.throws(() => validateRequest({ ...OK, project: 'az-express-test', confirmProject: 'az-express-test' }), /autorisé/);
  assert.throws(() => validateRequest({ ...OK, project: 'demo-az-test', confirmProject: 'demo-az-test' }), /autorisé/);
});

test('validateRequest : refuse une confirmation absente ou différente', () => {
  assert.throws(() => validateRequest({ ...OK, confirmProject: undefined }), /confirm-project/);
  assert.throws(() => validateRequest({ ...OK, confirmProject: 'autre-projet' }), /confirm-project/);
});

test('validateRequest : refuse une variable d\'environnement pointant la production', () => {
  assert.throws(() => validateRequest({ ...OK, env: { GOOGLE_CLOUD_PROJECT: 'az-express-b0469' } }), /production/i);
  assert.throws(() => validateRequest({ ...OK, env: { GCLOUD_PROJECT: 'az-express-clean' } }), /production/i);
});

test('validateRequest : refuse tout email hors de la liste blanche fermée', () => {
  assert.throws(() => validateRequest({ ...OK, emails: ['admin.test@az-test.invalid'] }), /non autorisée/);
  assert.throws(() => validateRequest({ ...OK, emails: ['client.test@az-test.invalid', 'vendeur.test@az-test.invalid'] }), /non autorisée/);
  assert.throws(() => validateRequest({ ...OK, emails: ['nimporte.quoi@gmail.com'] }), /non autorisée/);
});

test('validateRequest : refuse une liste vide', () => {
  assert.throws(() => validateRequest({ ...OK, emails: [] }), /email requis/);
});

test('validateRequest : déduplique les emails répétés', () => {
  const { emails } = validateRequest({ ...OK, emails: [ALLOWED_EMAILS[0], ALLOWED_EMAILS[0]] });
  assert.deepEqual(emails, [ALLOWED_EMAILS[0]]);
});

test('buildPlan : ne mentionne aucune opération Firestore ni création de compte', () => {
  const plan = buildPlan({ project: ALLOWED_PROJECT, emails: [...ALLOWED_EMAILS] });
  assert.match(plan.operation, /mot de passe/i);
  assert.match(plan.operation, /aucune création de compte/i);
  assert.match(plan.firestore, /Aucune opération Firestore/);
});

test('resetPasswords : ne crée jamais de compte (échoue si introuvable, ne tente pas createUser)', async () => {
  let createUserCalled = false;
  const getAuth = () => ({
    getUserByEmail: async () => { const e = new Error('not found'); e.code = 'auth/user-not-found'; throw e; },
    // Volontairement absent : createUser. S'il était appelé, l'absence de cette méthode ferait échouer le test.
    createUser: async () => { createUserCalled = true; throw new Error('createUser ne doit jamais être appelé'); },
    updateUser: async () => { throw new Error('ne doit pas être atteint'); },
  });
  await assert.rejects(
    resetPasswords({ project: ALLOWED_PROJECT, emails: [ALLOWED_EMAILS[0]], password: 'motdepasse-test-12', getAuth }),
  );
  assert.equal(createUserCalled, false);
});

test('resetPasswords : appelle updateUser avec UNIQUEMENT le mot de passe, rien d\'autre', async () => {
  const calls = [];
  const getAuth = () => ({
    getUserByEmail: async (email) => ({ uid: `uid-${email}` }),
    updateUser: async (uid, payload) => { calls.push({ uid, payload }); },
  });
  const results = await resetPasswords({
    project: ALLOWED_PROJECT, emails: [...ALLOWED_EMAILS], password: 'motdepasse-test-12', getAuth,
  });
  assert.equal(calls.length, 2);
  for (const call of calls) {
    assert.deepEqual(Object.keys(call.payload), ['password']);
    assert.equal(call.payload.password, 'motdepasse-test-12');
  }
  assert.deepEqual(results.map((r) => r.email), ALLOWED_EMAILS);
});

test('resetPasswords : refuse un mot de passe trop court, sans appeler Auth', async () => {
  let authTouched = false;
  const getAuth = () => { authTouched = true; return {}; };
  await assert.rejects(
    resetPasswords({ project: ALLOWED_PROJECT, emails: [ALLOWED_EMAILS[0]], password: 'court', getAuth }),
    /12 caractères/,
  );
  assert.equal(authTouched, false);
});

test('main() en dry-run (sans --execute) : n\'appelle jamais Firebase et ne modifie rien', async () => {
  const argv = ['--project', ALLOWED_PROJECT, '--confirm-project', ALLOWED_PROJECT,
    '--email', ALLOWED_EMAILS[0], '--email', ALLOWED_EMAILS[1]];
  const result = await main(argv, {});
  assert.equal(result.executed, false);
  assert.deepEqual(result.plan.emails, ALLOWED_EMAILS);
});

test('main() dry-run : n\'affiche jamais le mot de passe dans la sortie', async () => {
  const logs = [];
  const originalLog = console.log;
  console.log = (...args) => logs.push(args.join(' '));
  try {
    const argv = ['--project', ALLOWED_PROJECT, '--confirm-project', ALLOWED_PROJECT, '--email', ALLOWED_EMAILS[0]];
    await main(argv, { AZ_TEST_PASSWORD: 'ne-doit-jamais-apparaitre-12' });
  } finally {
    console.log = originalLog;
  }
  const joined = logs.join('\n');
  assert.doesNotMatch(joined, /ne-doit-jamais-apparaitre-12/);
  assert.match(joined, /DRY-RUN/);
});

test('main() : refuse un argument CLI inconnu', async () => {
  await assert.rejects(main(['--unknown'], {}), /Argument inconnu/);
});
