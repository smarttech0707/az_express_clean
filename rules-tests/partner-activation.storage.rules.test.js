// Étapes B4 + B5 — un partenaire (restaurant, vendeur, boulangerie) non activé ne
// peut ni téléverser, ni remplacer, ni supprimer de fichier professionnel dans
// Cloud Storage, même avec un client modifié.
//
// ATTENTION : l'émulateur Storage N'APPLIQUE PAS la limite de production de 2
// documents Firestore distincts par évaluation (vérifié par sonde : 3 documents
// sont acceptés), et la documentation ne précise ni l'évaluation paresseuse ni
// le décompte des documents inexistants. La dernière section vérifie donc
// STATIQUEMENT le budget de chaque règle dans le PIRE cas.
//
// Exécution : npm run test:storage
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {
  initializeTestEnvironment, assertSucceeds, assertFails,
} = require('@firebase/rules-unit-testing');
const { ref, uploadBytes, deleteObject, getBytes } = require('firebase/storage');

const RULES_PATH = process.env.STORAGE_RULES_PATH || path.join(__dirname, '..', 'storage.rules');
let env;

test.before(async () => {
  env = await initializeTestEnvironment({
    projectId: process.env.GCLOUD_PROJECT || 'az-express-b0469',
    storage: { rules: fs.readFileSync(RULES_PATH, 'utf8') },
    firestore: {},
  });
});
test.after(async () => env?.cleanup());

const jpeg = new Uint8Array([0xff, 0xd8, 0xff, 0xd9]);
const mp4 = new Uint8Array([0, 0, 0, 16, 0x66, 0x74, 0x79, 0x70]);
const audio = new Uint8Array([1, 2, 3, 4]);
const KINDS = {
  image: { bytes: jpeg, contentType: 'image/jpeg' },
  png: { bytes: jpeg, contentType: 'image/png' },
  video: { bytes: mp4, contentType: 'video/mp4' },
  audio: { bytes: audio, contentType: 'audio/mpeg' },
};

const password = { firebase: { sign_in_provider: 'password' } };
const withClaim = { ...password, partnerMustChangePassword: true };
const storageFor = (uid, token = password) => env.authenticatedContext(uid, token).storage();
const RESTO_EMAIL = { email: 'r1@az-restaurant.ci' };

async function seedFirestore() {
  await env.clearFirestore();
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    await db.doc('admins/root').set({ role: 'super', isActive: true });
    await db.doc('restaurant_owners/r1').set({ restaurantId: 'rest1', uid: 'r1' });
    await db.doc('marketplace_products/p1').set({ sellerId: 's1', status: 'active' });
    await db.doc('marketplace_chats/mp_p1_buyer1').set({ sellerId: 's1', buyerId: 'buyer1' });
  });
}
const setJournal = (uid, mustChangePassword) => env.withSecurityRulesDisabled(
  (ctx) => ctx.firestore().doc(`partner_provisioning/${uid}`).set({ kind: 'seller', mustChangePassword }));
// Projection en lecture seule du journal, écrite par le serveur dans restaurant_owners/{uid}.
const setProjection = (uid, mustChangePassword) => env.withSecurityRulesDisabled(
  (ctx) => ctx.firestore().doc(`restaurant_owners/${uid}`).set(
    { restaurantId: 'rest1', uid, mustChangePassword }, { merge: true }));
async function seedFile(filePath, kind) {
  await env.withSecurityRulesDisabled(async (ctx) => {
    await uploadBytes(ref(ctx.storage(), filePath), KINDS[kind].bytes, { contentType: KINDS[kind].contentType });
  });
}
const put = (storage, filePath, kind) => uploadBytes(ref(storage, filePath), KINDS[kind].bytes, { contentType: KINDS[kind].contentType });

// authority:
//  'journal'    = journal serveur prioritaire (jeton ancien refusé, revendication périmée tolérée) ;
//  'projection' = restaurant_owners/{uid}.mustChangePassword (projection du journal, même effet) ;
//  'token'      = revendication du jeton seule (limite connue : budget de 2 documents atteint).
const surfaces = [
  { name: 'vendeur : photo de profil', uid: 's1', file: 'seller_photos/s1/profile.jpg', kind: 'image', authority: 'journal' },
  { name: 'boulangerie : logo', uid: 'b1', file: 'boulangerie_logos/b1/logo.jpg', kind: 'image', authority: 'journal', admin: true },
  { name: 'véhicules : image', uid: 's1', file: 'vehicle_listings/s1/l1/images/p1.jpg', kind: 'image', authority: 'journal' },
  { name: 'véhicules : vidéo', uid: 's1', file: 'vehicle_listings/s1/l1/videos/v1.mp4', kind: 'video', authority: 'journal' },
  { name: 'véhicules : logo vendeur', uid: 's1', file: 'vehicle_seller_profiles/s1/logo/logo.png', kind: 'png', authority: 'journal' },
  { name: 'restaurant : logo', uid: 'r1', file: 'restaurant_logos/rest1/logo.jpg', kind: 'image', authority: 'projection', admin: true, email: true },
  { name: 'restaurant : photo de plat', uid: 'r1', file: 'restaurant_menu_items/rest1/plat.jpg', kind: 'image', authority: 'projection', admin: true, email: true },
  { name: 'restaurant : couverture', uid: 'r1', file: 'restaurant_covers/rest1/cover.jpg', kind: 'image', authority: 'projection', admin: true, email: true },
  { name: 'Marketplace : photo d\'annonce', uid: 's1', file: 'marketplace/p1/photo.jpg', kind: 'image', authority: 'token' },
  { name: 'Marketplace : audio de conversation (vendeur)', uid: 's1', file: 'mp_chat_audio/mp_p1_buyer1/a.mp3', kind: 'audio', authority: 'token' },
];

for (const s of surfaces) {
  const tokenFor = (base) => (s.email ? { ...base, ...RESTO_EMAIL } : base);
  const as = (base) => storageFor(s.uid, tokenFor(base));
  const markPending = (pending) => (s.authority === 'projection' ? setProjection(s.uid, pending) : setJournal(s.uid, pending));

  test.describe(s.name, () => {
    test.beforeEach(seedFirestore);

    test('NON activé (revendication seule) : téléversement, remplacement et suppression refusés', async () => {
      await assertFails(put(as(withClaim), s.file, s.kind));
      await seedFile(s.file, s.kind);
      await assertFails(put(as(withClaim), s.file, s.kind)); // remplacement
      await assertFails(deleteObject(ref(as(withClaim), s.file)));
    });

    test('lecture inchangée pour un partenaire non activé', async () => {
      await seedFile(s.file, s.kind);
      await assertSucceeds(getBytes(ref(as(withClaim), s.file)));
    });

    test('compte historique (ni indicateur ni revendication) : comportement préservé', async () => {
      await assertSucceeds(put(as(password), s.file, s.kind));
      await assertSucceeds(put(as(password), s.file, s.kind));
      await assertSucceeds(deleteObject(ref(as(password), s.file)));
    });

    test('activé après changement (indicateur levé, jeton renouvelé) : comportement normal', async () => {
      await markPending(false);
      await assertSucceeds(put(as(password), s.file, s.kind));
      await assertSucceeds(put(as(password), s.file, s.kind));
      await assertSucceeds(deleteObject(ref(as(password), s.file)));
    });

    if (s.authority !== 'token') {
      test('JETON ANCIEN après réinitialisation (indicateur serveur, jeton sans revendication) : refusé', async () => {
        await markPending(true);
        await assertFails(put(as(password), s.file, s.kind));
        await seedFile(s.file, s.kind);
        await assertFails(put(as(password), s.file, s.kind));
        await assertFails(deleteObject(ref(as(password), s.file)));
      });
      test('NON activé (indicateur serveur ET revendication) : refusé', async () => {
        await markPending(true);
        await assertFails(put(as(withClaim), s.file, s.kind));
      });
      test('revendication PÉRIMÉE après activation : cohérent avec l\'indicateur serveur (autorisé)', async () => {
        await markPending(false);
        await assertSucceeds(put(as(withClaim), s.file, s.kind));
      });
    } else {
      // Limite connue : ces chemins lisent déjà un document de propriété
      // (marketplace_products / marketplace_chats), budget de 2 documents atteint.
      test('LIMITE CONNUE : jeton ancien sans revendication encore accepté sur ce chemin', async () => {
        await setJournal(s.uid, true);
        await assertSucceeds(put(as(password), s.file, s.kind));
      });
      test('revendication périmée après activation : refusée jusqu\'à la reconnexion (le client se reconnecte)', async () => {
        await setJournal(s.uid, false);
        await assertFails(put(as(withClaim), s.file, s.kind));
      });
    }

    test('utilisateur tiers : aucun accès supplémentaire', async () => {
      await seedFile(s.file, s.kind);
      const intrus = s.email ? { ...password, email: 'intrus@az-restaurant.ci' } : password;
      await assertFails(put(storageFor('intrus', intrus), s.file, s.kind));
      await assertFails(deleteObject(ref(storageFor('intrus', intrus), s.file)));
      await assertFails(put(storageFor('intrus'), s.file, s.kind));
    });

    test('utilisateur anonyme / non authentifié : refusé', async () => {
      await assertFails(put(storageFor(s.uid, { firebase: { sign_in_provider: 'anonymous' } }), s.file, s.kind));
      await assertFails(put(env.unauthenticatedContext().storage(), s.file, s.kind));
    });

    if (s.admin) {
      test('administrateur : permissions inchangées (avec ou sans revendication sur son jeton)', async () => {
        for (const token of [password, withClaim]) {
          await assertSucceeds(put(storageFor('root', token), s.file, s.kind));
          await assertSucceeds(deleteObject(ref(storageFor('root', token), s.file)));
        }
      });
    }
  });
}

test.describe('restaurants : preuve de propriété et discriminateur d\'e-mail', () => {
  test.beforeEach(seedFirestore);
  const file = 'restaurant_logos/rest1/logo.jpg';
  const owner = (token) => storageFor('r1', { ...token, ...RESTO_EMAIL });

  test('projection absente (compte historique) : la revendication du jeton décide encore', async () => {
    await assertSucceeds(put(owner(password), file, 'image'));
    await assertFails(put(owner(withClaim), file, 'image'));
  });

  test('projection présente : elle fait autorité sur la revendication (périmée ou absente)', async () => {
    await setProjection('r1', true);
    await assertFails(put(owner(password), file, 'image'));
    await assertFails(put(owner(withClaim), file, 'image'));
    await setProjection('r1', false);
    await assertSucceeds(put(owner(password), file, 'image'));
    await assertSucceeds(put(owner(withClaim), file, 'image'));
  });

  test('sans e-mail de restaurateur, le propriétaire n\'est PAS reconnu (le discriminateur est nécessaire)', async () => {
    await assertFails(put(storageFor('r1', password), file, 'image'));
  });

  test('l\'e-mail seul n\'accorde rien : restaurateur d\'un AUTRE restaurant, ou sans document de propriété', async () => {
    await assertFails(put(storageFor('r1', { ...password, ...RESTO_EMAIL }), 'restaurant_logos/autre/logo.jpg', 'image'));
    await assertFails(put(storageFor('inconnu', { ...password, email: 'inconnu@az-restaurant.ci' }), file, 'image'));
  });

  test('un e-mail imitant le domaine ne passe pas (domaine exact exigé)', async () => {
    for (const email of ['r1@az-restaurant.ci.evil.com', 'r1@xaz-restaurant.ci', 'r1@az-restaurantXci']) {
      await assertFails(put(storageFor('r1', { ...password, email }), file, 'image'));
    }
  });

  test('administrateur sans e-mail de restaurateur : accès conservé ; avec revendication aussi', async () => {
    await assertSucceeds(put(storageFor('root', { ...password, email: 'admin@example.test' }), file, 'image'));
    await assertSucceeds(put(storageFor('root', { ...withClaim, email: 'admin@example.test' }), file, 'image'));
  });

  test('un restaurateur n\'obtient aucun droit administrateur sur les autres restaurants', async () => {
    await setProjection('r1', false);
    await assertFails(put(owner(password), 'restaurant_covers/autre/cover.jpg', 'image'));
    await assertFails(put(owner(password), 'restaurant_menu_items/autre/plat.jpg', 'image'));
  });
});

test.describe('client ordinaire et opérations d\'acheteur', () => {
  test.beforeEach(seedFirestore);

  test('client ordinaire : annonce de véhicule et photo Marketplace inchangées', async () => {
    await assertSucceeds(put(storageFor('client9'), 'vehicle_listings/client9/l1/images/p1.jpg', 'image'));
    await assertSucceeds(put(storageFor('client9'), 'vehicle_seller_profiles/client9/logo/logo.png', 'png'));
    await assertSucceeds(put(storageFor('client9'), 'marketplace/tmp_123/photo.jpg', 'image'));
  });

  test('acheteur : audio de conversation inchangé, même si l\'acheteur est un vendeur non activé', async () => {
    await assertSucceeds(put(storageFor('buyer1'), 'mp_chat_audio/mp_p1_buyer1/a.mp3', 'audio'));
    await setJournal('s1', true);
    await assertSucceeds(put(storageFor('s1', withClaim), 'mp_chat_audio/mp_p9_s1/a.mp3', 'audio'));
  });

  test('chemins administrateur uniquement : toujours fermés aux partenaires', async () => {
    for (const file of ['boutique_products/x.jpg', 'restaurant_menus/x.jpg', 'bakery/b1/x.jpg']) {
      await assertFails(put(storageFor('s1'), file, 'image'));
      await assertFails(put(storageFor('b1'), file, 'image'));
    }
    await assertSucceeds(put(storageFor('root'), 'boutique_products/x.jpg', 'image'));
  });
});

// ═════════════════════════════════════════════════════════════════════════════
// Budget de documents Firestore par règle (limite de production : 2 documents)
// ═════════════════════════════════════════════════════════════════════════════
const source = fs.readFileSync(RULES_PATH, 'utf8').replace(/\r\n/g, '\n')
  .split('\n').map((line) => line.replace(/\/\/.*$/, '')).join('\n');

function balanced(text, openIndex) {
  let depth = 0;
  for (let i = openIndex; i < text.length; i += 1) {
    if (text[i] === '{') depth += 1;
    if (text[i] === '}') { depth -= 1; if (depth === 0) return i; }
  }
  throw new Error('accolades non équilibrées');
}
const helpers = new Map();
for (const match of source.matchAll(/function\s+(\w+)\s*\([^)]*\)\s*\{/g)) {
  const open = match.index + match[0].length - 1;
  helpers.set(match[1], source.slice(open + 1, balanced(source, open)));
}
const matchBlocks = [];
for (const match of source.matchAll(/match\s+(\/\S+)\s+\{/g)) {
  const open = match.index + match[0].length - 1;
  matchBlocks.push({ path: match[1], body: source.slice(open + 1, balanced(source, open)) });
}
function allowStatements(pathName) {
  return matchBlocks.filter((b) => b.path === pathName).flatMap((b) =>
    [...b.body.matchAll(/allow\s+([\w, ]+?)\s*:\s*if\s+([\s\S]*?);/g)]
      .map((m) => ({ ops: m[1].split(',').map((o) => o.trim()), expr: m[2] })));
}
function documentsOf(expression, seen = new Set()) {
  const docs = new Set();
  const lets = new Map();
  const collect = (text) => {
    for (const m of text.matchAll(/let\s+(\w+)\s*=\s*(\/databases\/\(default\)\/documents\/[^;]+);/g)) lets.set(m[1], m[2]);
    for (const m of text.matchAll(/firestore\.(?:get|exists)\(\s*(\/databases\/\(default\)\/documents\/[^)]*\)?[^)]*?|\w+)\s*\)/g)) {
      const arg = m[1].trim();
      const resolved = lets.get(arg) || arg;
      docs.add(resolved.replace('/databases/(default)/documents/', '').replace(/\$\([^)]*\)/g, '$(x)'));
    }
    for (const m of text.matchAll(/\b(\w+)\s*\(/g)) {
      const name = m[1];
      if (helpers.has(name) && !seen.has(name)) {
        seen.add(name);
        collect(helpers.get(name));
      }
    }
  };
  collect(expression);
  return docs;
}

const writeStatements = (pathName) => allowStatements(pathName).filter((s) => !s.ops.includes('read'));
const protectedPaths = [
  '/seller_photos/{sellerId}/{file}', '/boulangerie_logos/{boulangerieId}/{file}',
  '/vehicle_listings/{sellerUid}/{listingId}/images/{file}', '/vehicle_listings/{sellerUid}/{listingId}/videos/{file}',
  '/vehicle_seller_profiles/{sellerUid}/logo/{file}', '/restaurant_logos/{restaurantId}/{file}',
  '/restaurant_menu_items/{restaurantId}/{file}', '/restaurant_covers/{restaurantId}/cover.jpg',
  '/marketplace/{productId}/{file}', '/mp_chat_audio/{chatId}/{file}',
];
const GUARDS = /partnerActivated\(\)|partnerTokenActivated\(\)|restaurantOwnerActivated\(|isMpChatWriter\(/;
const ADMIN_EXCLUSION = /!isRestaurantOwnerEmail\(\)|!isOwnerPath\(/;

test('budget statique (PIRE cas, sans court-circuit) : chaque règle d\'écriture tient en 2 documents, administrateur compris', () => {
  for (const pathName of protectedPaths) {
    const statements = writeStatements(pathName);
    assert.ok(statements.length >= 2, `${pathName} : règles d'écriture introuvables`);
    for (const statement of statements) {
      const docs = documentsOf(statement.expr);
      assert.ok(docs.size <= 2,
        `${pathName} [${statement.ops}] : ${docs.size} documents (${[...docs]}) > 2 (limite de production)`);
    }
  }
});

test('chaque règle d\'écriture est soit gardée (propriétaire), soit réservée à l\'administrateur avec exclusion sans document', () => {
  for (const pathName of protectedPaths) {
    for (const statement of writeStatements(pathName)) {
      const isAdminStatement = /isAdmin\(\)/.test(statement.expr);
      if (isAdminStatement) {
        assert.equal(GUARDS.test(statement.expr), false, `${pathName} : règle admin et propriétaire mélangées`);
        assert.ok(ADMIN_EXCLUSION.test(statement.expr), `${pathName} [${statement.ops}] : exclusion du propriétaire (sans document) absente`);
      } else {
        assert.ok(GUARDS.test(statement.expr), `${pathName} [${statement.ops}] : garde d'activation absente`);
      }
    }
  }
});

test('propriétaire et administrateur : le discriminateur précède toute lecture de document (aucun document inutile lu)', () => {
  const firstDocAccess = /firestore\.(get|exists)|\bisAdmin\(\)|restaurantOwnerActivated\(|partnerActivated\(\)|isMpChatWriter\(/;
  for (const pathName of ['/restaurant_logos/{restaurantId}/{file}', '/restaurant_menu_items/{restaurantId}/{file}',
    '/restaurant_covers/{restaurantId}/cover.jpg', '/boulangerie_logos/{boulangerieId}/{file}']) {
    for (const statement of writeStatements(pathName)) {
      const discriminator = statement.expr.search(/!?isRestaurantOwnerEmail\(\)|!?isOwnerPath\(/);
      const access = statement.expr.search(firstDocAccess);
      assert.ok(discriminator >= 0, `${pathName} : discriminateur absent`);
      assert.ok(discriminator < access, `${pathName} [${statement.ops}] : lecture de document avant le discriminateur`);
    }
  }
});

test('le journal n\'est lu que par les règles qui ne consomment que isAuth() en plus', () => {
  for (const pathName of protectedPaths) {
    for (const statement of writeStatements(pathName)) {
      const docs = documentsOf(statement.expr);
      const usesJournal = [...docs].some((d) => d.startsWith('partner_provisioning/'));
      if (/partnerActivated\(\)/.test(statement.expr)) {
        assert.ok(usesJournal);
        assert.deepEqual([...docs].sort(), ['account_tombstones/$(x)', 'partner_provisioning/$(x)']);
      } else {
        assert.equal(usesJournal, false, `${pathName} : le budget est déjà atteint, pas de lecture du journal ici`);
      }
    }
  }
});

test('restaurants : la preuve de propriété et l\'activation partagent UN SEUL document (restaurant_owners)', () => {
  assert.deepEqual([...documentsOf(helpers.get('restaurantOwnerActivated'))], ['restaurant_owners/$(x)']);
  assert.deepEqual([...documentsOf(helpers.get('isRestaurantOwnerEmail'))], []);
  assert.deepEqual([...documentsOf(helpers.get('partnerTokenActivated'))], []);
  assert.deepEqual([...documentsOf(helpers.get('partnerActivated'))], ['partner_provisioning/$(x)']);
});

test('la lecture des chemins protégés n\'est pas modifiée', () => {
  for (const pathName of protectedPaths) {
    for (const statement of allowStatements(pathName).filter((s) => s.ops.includes('read'))) {
      assert.equal(/partner(Token)?Activated|restaurantOwnerActivated|isMpChatWriter|isRestaurantOwnerEmail/.test(statement.expr), false, pathName);
    }
  }
});

test('les chemins administrateur uniquement ne sont pas touchés par la garde', () => {
  for (const pathName of ['/boutique_products/{file}', '/restaurant_menus/{file}', '/bakery/{boulangerieId}/{file}']) {
    for (const statement of allowStatements(pathName)) {
      assert.equal(/partner(Token)?Activated|restaurantOwnerActivated|isRestaurantOwnerEmail/.test(statement.expr), false, pathName);
    }
  }
});
