// Note du livreur par le client. Cause du bug « la note ne se valide pas » :
// l'app écrivait `livreurs/{id}.avgRating` depuis le client, ce que les règles
// refusent (à raison). Ces tests figent le contrat : le client note UNIQUEMENT
// sa commande livrée ; la moyenne du livreur reste réservée au serveur.
//
// Exécution : npm run test:rules
const test = require('node:test');
const fs = require('node:fs');
const path = require('node:path');
const { initializeTestEnvironment, assertSucceeds, assertFails } = require('@firebase/rules-unit-testing');

const RULES = fs.readFileSync(path.join(__dirname, '..', 'firestore.rules'), 'utf8');
const password = { firebase: { sign_in_provider: 'password' } };

const delivered = {
  clientId: 'c1', driverId: 'd1', status: 'delivered', paymentMethod: 'cash',
  isPaid: true, budget: 1500,
};

async function env(projectId) {
  const e = await initializeTestEnvironment({ projectId, firestore: { rules: RULES } });
  await e.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    await db.doc('livreurs/d1').set({ wallet: 700, avgRating: 4, ratingCount: 3 });
    await db.doc('orders/done').set(delivered);
    await db.doc('orders/active').set({ ...delivered, status: 'accepted' });
    await db.doc('orders/other').set({ ...delivered, clientId: 'c2' });
  });
  return e;
}

test('le client note sa commande livrée (rating seul)', async () => {
  const e = await env('az-rating-ok');
  try {
    const db = e.authenticatedContext('c1', password).firestore();
    await assertSucceeds(db.doc('orders/done').update({ rating: 5 }));
  } finally { await e.cleanup(); }
});

test('le client ne peut pas écrire la moyenne du livreur (cause du bug historique)', async () => {
  const e = await env('az-rating-driver');
  try {
    const db = e.authenticatedContext('c1', password).firestore();
    await assertFails(db.doc('livreurs/d1').update({ avgRating: 5, ratingCount: 4 }));
    await assertFails(db.doc('livreurs/d1').update({ avgRating: 5 }));
  } finally { await e.cleanup(); }
});

test('la note ne passe pas avec un autre champ (statut, montant, marqueur serveur)', async () => {
  const e = await env('az-rating-fields');
  try {
    const db = e.authenticatedContext('c1', password).firestore();
    await assertFails(db.doc('orders/done').update({ rating: 5, budget: 1 }));
    await assertFails(db.doc('orders/done').update({ rating: 5, status: 'cancelled' }));
    await assertFails(db.doc('orders/done').update({ rating: 5, driverRatingApplied: true }));
    await assertFails(db.doc('orders/done').update({ driverRatingApplied: true }));
  } finally { await e.cleanup(); }
});

test('on ne note pas une commande non livrée', async () => {
  const e = await env('az-rating-active');
  try {
    const db = e.authenticatedContext('c1', password).firestore();
    await assertFails(db.doc('orders/active').update({ rating: 5 }));
  } finally { await e.cleanup(); }
});

test('on ne note pas la commande d’un autre client', async () => {
  const e = await env('az-rating-other');
  try {
    const db = e.authenticatedContext('c1', password).firestore();
    await assertFails(db.doc('orders/other').update({ rating: 5 }));
  } finally { await e.cleanup(); }
});

test('note invalide refusée : 0, 6, décimale, texte, null', async () => {
  const e = await env('az-rating-invalid');
  try {
    const db = e.authenticatedContext('c1', password).firestore();
    for (const bad of [0, 6, -1, 4.5, '5', null]) {
      await assertFails(db.doc('orders/done').update({ rating: bad }));
    }
    await assertSucceeds(db.doc('orders/done').update({ rating: 5 }));
  } finally { await e.cleanup(); }
});

test('une commande ne se note qu’une fois : ni modification ni retrait', async () => {
  const e = await env('az-rating-once');
  try {
    await e.withSecurityRulesDisabled(async (ctx) => {
      await ctx.firestore().doc('orders/rated').set({ ...delivered, rating: 3 });
    });
    const db = e.authenticatedContext('c1', password).firestore();
    await assertFails(db.doc('orders/rated').update({ rating: 5 }));
    await assertFails(db.doc('orders/rated').update({ rating: 1 }));
    const { deleteField } = require('firebase/firestore');
    await assertFails(db.doc('orders/rated').update({ rating: deleteField() }));
  } finally { await e.cleanup(); }
});

test('la note du vendeur suit les mêmes règles (1..5, une seule fois)', async () => {
  const e = await env('az-rating-seller');
  try {
    const db = e.authenticatedContext('c1', password).firestore();
    await assertFails(db.doc('orders/done').update({ sellerRating: 9 }));
    await assertSucceeds(db.doc('orders/done').update({ sellerRating: 4 }));
    await assertFails(db.doc('orders/done').update({ sellerRating: 2 }));
  } finally { await e.cleanup(); }
});

test('un autre utilisateur, un livreur ou un anonyme sans propriété ne notent pas', async () => {
  const e = await env('az-rating-others');
  try {
    await assertFails(e.authenticatedContext('d1', password).firestore().doc('orders/done').update({ rating: 5 }));
    await assertFails(e.authenticatedContext('c2', password).firestore().doc('orders/done').update({ rating: 5 }));
    await assertFails(e.unauthenticatedContext().firestore().doc('orders/done').update({ rating: 5 }));
  } finally { await e.cleanup(); }
});

test('le livreur assigné ne peut pas écrire ni modifier les notes ni le marqueur serveur', async () => {
  const e = await env('az-rating-driver-self');
  try {
    const db = e.authenticatedContext('d1', password).firestore();
    await assertFails(db.doc('orders/done').update({ rating: 5 }));
    await assertFails(db.doc('orders/done').update({ sellerRating: 5 }));
    await assertFails(db.doc('orders/done').update({ driverRatingApplied: true }));
  } finally { await e.cleanup(); }
});
