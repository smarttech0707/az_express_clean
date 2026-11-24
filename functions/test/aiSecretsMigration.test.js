'use strict';

/**
 * Migration des clés IA vers Secret Manager — vérifications structurelles.
 *
 * `defineSecret` monte la valeur du secret sous le MÊME nom de variable
 * d'environnement au runtime. Ces tests verrouillent donc deux choses :
 *   1. les providers continuent de lire `process.env.<NOM>` (donc la migration
 *      ne casse rien et ne requiert aucun changement de provider) ;
 *   2. la déclaration `secrets:` respecte le moindre privilège — une fonction
 *      qui n'appelle aucun modèle ne doit déclarer aucune clé IA.
 *
 * Aucun réseau, aucune valeur de secret : les clés utilisées sont factices.
 */

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.join(__dirname, '..');
const indexSource = fs.readFileSync(path.join(ROOT, 'index.js'), 'utf8');

// Fournisseurs EN SERVICE : Claude (principal) + Gemini (repli). Ce sont les
// seuls dont la clé doit être déclarée — `defineSecret` crée une dépendance de
// déploiement, et les quatre autres secrets n'existent pas dans Secret Manager.
const ACTIVE_AI_KEYS = ['ANTHROPIC_API_KEY', 'GEMINI_API_KEY'];
// Fournisseurs OPTIONNELS : code conservé, mais ni requis ni monté.
const OPTIONAL_AI_KEYS = ['OPENAI_API_KEY', 'GROQ_API_KEY',
  'MISTRAL_API_KEY', 'DEEPSEEK_API_KEY'];

// ── 1. Déclaration defineSecret ─────────────────────────────────────────────
test('SM1. seules les clés des fournisseurs en service sont déclarées', () => {
  for (const key of ACTIVE_AI_KEYS) {
    assert.ok(
      indexSource.includes(`defineSecret('${key}')`),
      `${key} doit passer par defineSecret, jamais par functions/.env seul`,
    );
  }
  for (const key of OPTIONAL_AI_KEYS) {
    assert.ok(
      !indexSource.includes(`defineSecret('${key}')`),
      `${key} ne doit pas être déclarée : son secret n'existe pas et le `
      + 'déploiement échouerait',
    );
  }
});

test('SM2. les variables NON sensibles ne sont pas migrées inutilement', () => {
  for (const nonSecret of ['GEMINI_MODEL', 'OPENAI_MODEL', 'AI_DEFAULT_PROVIDER',
    'AI_ENABLE_FALLBACK', 'FEEXPAY_SHOP_ID']) {
    assert.ok(!indexSource.includes(`defineSecret('${nonSecret}')`),
      `${nonSecret} est une configuration, pas un secret`);
  }
});

// ── 2. Moindre privilège ────────────────────────────────────────────────────
test('SM3. azIaChat reçoit Anthropic + Gemini uniquement, et AUCUN secret FeexPay', () => {
  const block = indexSource.slice(
    indexSource.indexOf('azIaChatSecrets: ['),
    indexSource.indexOf('aiConfirmActionSecrets:'),
  );
  assert.ok(block.length > 0, 'bloc azIaChatSecrets introuvable');
  for (const key of ACTIVE_AI_KEYS) {
    assert.ok(block.includes(`${key}_SECRET`), `azIaChat doit déclarer ${key}`);
  }
  for (const key of OPTIONAL_AI_KEYS) {
    assert.ok(!block.includes(`${key}_SECRET`),
      `${key} n'est pas dans la chaîne de repli actuelle : ne pas la monter`);
  }
  // azIaChat n'appelle jamais FEEXPAY_TOKEN.value() ni WEBHOOK_URL() :
  // ces appels vivent uniquement dans afterConfirm (aiConfirmAction).
  assert.ok(!block.includes('FEEXPAY_TOKEN_SECRET'),
    'azIaChat ne doit plus déclarer FEEXPAY_TOKEN');
  assert.ok(!block.includes('FEEXPAY_WEBHOOK_SECRET'),
    'azIaChat ne doit plus déclarer FEEXPAY_WEBHOOK_SECRET');
});

test('SM4. aiConfirmAction garde FeexPay et ne reçoit aucune clé IA', () => {
  const line = indexSource.split('\n').find((l) => l.includes('aiConfirmActionSecrets:'));
  assert.ok(line, 'aiConfirmActionSecrets introuvable');
  assert.ok(line.includes('FEEXPAY_TOKEN_SECRET') && line.includes('FEEXPAY_WEBHOOK_SECRET'),
    'les protections FeexPay de aiConfirmAction sont conservées');
  for (const key of [...ACTIVE_AI_KEYS, ...OPTIONAL_AI_KEYS]) {
    assert.ok(!line.includes(`${key}_SECRET`),
      `aiConfirmAction n'appelle aucun modèle : ${key} ne doit pas y être déclaré`);
  }
});

test('SM5. listAiToolExecutions ne déclare aucun secret', () => {
  const source = fs.readFileSync(path.join(ROOT, 'aiToolExecutions.js'), 'utf8');
  assert.ok(!/secrets\s*:/.test(source),
    'une vue de supervision en lecture seule ne doit porter aucun secret');
  for (const key of [...ACTIVE_AI_KEYS, ...OPTIONAL_AI_KEYS, 'FEEXPAY_TOKEN']) {
    assert.ok(!source.includes(key), `${key} ne doit pas apparaître dans ce module`);
  }
});

test('SM6. clearAiHistory et les schedulers IA ne déclarent aucun secret', () => {
  const source = fs.readFileSync(path.join(ROOT, 'azia', 'index.js'), 'utf8');
  // Seules deux déclarations `secrets:` doivent exister : azIaChat et
  // aiConfirmAction, toutes deux alimentées par les listes d'index.js.
  const declarations = source.match(/secrets:\s*\w+/g) || [];
  assert.deepEqual(
    declarations.map((d) => d.replace(/\s+/g, ' ')).sort(),
    ['secrets: aiConfirmActionSecrets', 'secrets: azIaChatSecrets'],
    'aucune autre fonction AZ IA ne doit déclarer de secret',
  );
});

// ── 3. Les providers lisent toujours process.env (donc rien à changer) ──────
test('SM7. les providers lisent process.env — compatible Secret Manager', async () => {
  const cases = [
    ['GEMINI_API_KEY', '../azia/providers/GeminiProvider', { GEMINI_MODEL: 'modele-factice' }],
    ['OPENAI_API_KEY', '../azia/providers/OpenAIProvider', {}],
    ['GROQ_API_KEY', '../azia/providers/GroqProvider', {}],
    ['MISTRAL_API_KEY', '../azia/providers/MistralProvider', {}],
    ['DEEPSEEK_API_KEY', '../azia/providers/DeepSeekProvider', {}],
    ['ANTHROPIC_API_KEY', '../azia/providers/ClaudeProvider', {}],
  ];
  for (const [envName, modulePath, extra] of cases) {
    const Provider = require(modulePath);
    const saved = { [envName]: process.env[envName], ...extra };
    for (const [k, v] of Object.entries(extra)) process.env[k] = v;
    try {
      delete process.env[envName];
      assert.equal(new Provider().isConfigured(), false,
        `${envName} absente → provider non configuré`);
      process.env[envName] = 'cle-factice-de-test-non-sensible';
      assert.equal(new Provider().isConfigured(), true,
        `${envName} présente (montée par defineSecret) → provider configuré`);
    } finally {
      for (const k of Object.keys(saved)) {
        if (saved[k] === undefined) delete process.env[k]; else process.env[k] = saved[k];
      }
    }
  }
});

test('SM8. absence de clé → erreur contrôlée, jamais un appel sortant', async () => {
  const GeminiProvider = require('../azia/providers/GeminiProvider');
  const { ProviderNotConfiguredError } = require('../azia/providers/errors');
  const savedKey = process.env.GEMINI_API_KEY;
  const savedModel = process.env.GEMINI_MODEL;
  // Un transport qui échoue le test s'il est jamais sollicité.
  GeminiProvider.transport = {
    request() { throw new Error('aucun appel réseau ne doit partir sans clé'); },
  };
  try {
    delete process.env.GEMINI_API_KEY;
    process.env.GEMINI_MODEL = 'modele-factice';
    await assert.rejects(
      new GeminiProvider().generateTurn({ messages: [], tools: [] }),
      (e) => e instanceof ProviderNotConfiguredError,
    );
  } finally {
    delete GeminiProvider.transport;
    if (savedKey === undefined) delete process.env.GEMINI_API_KEY; else process.env.GEMINI_API_KEY = savedKey;
    if (savedModel === undefined) delete process.env.GEMINI_MODEL; else process.env.GEMINI_MODEL = savedModel;
  }
});

// ── 4. Aucun secret journalisé ──────────────────────────────────────────────
test('SM9. aucun provider ne journalise quoi que ce soit', () => {
  const dir = path.join(ROOT, 'azia', 'providers');
  for (const file of fs.readdirSync(dir).filter((f) => f.endsWith('.js'))) {
    const source = fs.readFileSync(path.join(dir, file), 'utf8');
    const code = source.split('\n')
      .filter((l) => !l.trim().startsWith('//') && !l.trim().startsWith('*'))
      .join('\n');
    assert.ok(!/console\.(log|error|warn|info)/.test(code),
      `${file} ne doit journaliser aucune donnée de requête`);
  }
});

test('SM10. aucun code ne journalise process.env ni .value()', () => {
  const targets = [
    path.join(ROOT, 'index.js'),
    path.join(ROOT, 'azia', 'index.js'),
    path.join(ROOT, 'azia', 'pendingActions.js'),
    path.join(ROOT, 'aiToolExecutions.js'),
  ];
  for (const file of targets) {
    const source = fs.readFileSync(file, 'utf8');
    for (const line of source.split('\n')) {
      if (!/console\.(log|error|warn|info)/.test(line)) continue;
      assert.ok(!/process\.env/.test(line), `${path.basename(file)} : env journalisé → ${line.trim().slice(0, 60)}`);
      assert.ok(!/\.value\(\)/.test(line), `${path.basename(file)} : secret journalisé → ${line.trim().slice(0, 60)}`);
      assert.ok(!/JSON\.stringify\((process\.env|config)/.test(line),
        `${path.basename(file)} : sérialisation complète journalisée`);
    }
  }
});

test('SM11. le sanitizer partagé neutralise une clé IA factice', () => {
  const { sanitizeProviderMessage } = require('../feexpaySanitize');
  const fake = 'sk-faux-jeton-de-test-0000000000000000';
  const out = sanitizeProviderMessage(
    `request failed: Authorization: Bearer ${fake} token: ${fake}`,
  );
  assert.ok(!out.includes(fake), 'aucune valeur de clé ne doit survivre');
  assert.ok(out.includes('[REDACTED]'));
});
