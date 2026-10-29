'use strict';

// Garde de sortie réseau des émulateurs : FeexPay, SMS, API d'IA et tout service externe doivent être
// injoignables, quelle que soit la bibliothèque ; la machine locale reste joignable.
// Chaque cas tourne dans un processus enfant (le garde patche net.Socket globalement).

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const fs = require('node:fs');
const os = require('node:os');
const { spawnSync } = require('node:child_process');

const guardPath = path.join(__dirname, '..', '..', 'test-env', 'emulator', 'egressGuard.js');
const guard = require(guardPath);
const functionsDir = path.join(__dirname, '..');

function runChild(body) {
  const file = path.join(os.tmpdir(), `egress-${process.pid}-${Math.random().toString(36).slice(2)}.js`);
  fs.writeFileSync(file, `require(${JSON.stringify(guardPath)});\n${body}`);
  try {
    return spawnSync(process.execPath, [file], {
      cwd: functionsDir, encoding: 'utf8', timeout: 20000,
      env: { ...process.env, NODE_PATH: path.join(functionsDir, 'node_modules') },
    });
  } finally {
    fs.rmSync(file, { force: true });
  }
}

test('isAllowedHost : boucle locale uniquement', () => {
  for (const h of ['localhost', '127.0.0.1', '::1', '0.0.0.0', undefined, '']) assert.equal(guard.isAllowedHost(h), true, String(h));
  for (const h of ['api.feexpay.me', 'api.anthropic.com', 'api.openai.com', '8.8.8.8', '192.168.1.5',
    'metadata.google.internal', 'fcm.googleapis.com', '169.254.169.254']) assert.equal(guard.isAllowedHost(h), false, h);
});

for (const [name, body] of [
  ['axios → FeexPay', "require('axios').get('https://api.feexpay.me/').then(()=>process.exit(2),(e)=>{console.log(e.code||e.cause&&e.cause.code||e.message);process.exit(0)})"],
  ['https → API IA', "require('https').get('https://api.anthropic.com/').on('error',(e)=>{console.log(e.code);process.exit(0)}).on('response',()=>process.exit(2))"],
  ['fetch → OpenAI', "fetch('https://api.openai.com/v1/models').then(()=>process.exit(2),(e)=>{console.log(e.cause&&e.cause.code||e.message);process.exit(0)})"],
  ['http → IP publique', "require('http').get('http://93.184.216.34/').on('error',(e)=>{console.log(e.code);process.exit(0)}).on('response',()=>process.exit(2))"],
  ['net.connect (tableau normalisé)', "const n=require('net');n.connect({host:'93.184.216.34',port:80}).on('error',(e)=>{console.log(e.code);process.exit(0)}).on('connect',()=>process.exit(2))"],
  ['net.createConnection(port, host)', "const n=require('net');n.createConnection(80,'api.feexpay.me').on('error',(e)=>{console.log(e.code);process.exit(0)}).on('connect',()=>process.exit(2))"],
  ['tls.connect', "require('tls').connect({host:'api.feexpay.me',port:443}).on('error',(e)=>{console.log(e.code);process.exit(0)}).on('secureConnect',()=>process.exit(2))"],
  ['http2 → Google', "const c=require('http2').connect('https://fcm.googleapis.com');c.on('error',(e)=>{console.log(e.code);process.exit(0)});c.on('connect',()=>process.exit(2))"],
  ['SDK Anthropic', "new (require('@anthropic-ai/sdk'))({apiKey:'x',maxRetries:0}).messages.create({model:'m',max_tokens:1,messages:[{role:'user',content:'a'}]}).then(()=>process.exit(2),()=>process.exit(0))"],
  ['SDK OpenAI', "new (require('openai').OpenAI)({apiKey:'x',maxRetries:0}).models.list().then(()=>process.exit(2),()=>process.exit(0))"],
]) {
  test(`connexion sortante bloquée : ${name}`, () => {
    const r = runChild(`${body}; setTimeout(()=>process.exit(3),15000);`);
    assert.equal(r.status, 0, `${r.stdout}\n${r.stderr}`);
    assert.match(r.stderr, /AZ_EGRESS_BLOCKED/);
  });
}

test('connexion locale (boucle) toujours possible : émulateurs Firestore/Auth/Functions', () => {
  const r = runChild(`
    const http = require('http');
    const server = http.createServer((q, s) => s.end('ok')).listen(0, '127.0.0.1', () => {
      http.get({ host: '127.0.0.1', port: server.address().port }, (res) => {
        let d = ''; res.on('data', (c) => d += c);
        res.on('end', () => { console.log(d); server.close(); process.exit(0); });
      });
    });
    setTimeout(() => process.exit(3), 10000);`);
  assert.equal(r.status, 0, r.stderr);
  assert.equal(r.stdout.trim(), 'ok');
});

test('les fonctions mises en scène chargent le garde avant index.js et n’embarquent aucun secret', () => {
  const { isSecretFile } = require('../../test-env/stage-functions');
  for (const f of ['.env', '.env.local', '.env.az-express-b0469', '.secret.local', 'serviceAccountKey.json', 'x.pem', '.runtimeconfig.json']) {
    assert.equal(isSecretFile(f), true, f);
  }
  assert.equal(isSecretFile('index.js'), false);
});
