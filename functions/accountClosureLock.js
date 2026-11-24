'use strict';

// Socle L1 : verrou financier commun des writers (protocole 2D-2A.3 §1.4, « une seule implémentation »).
// NON BRANCHÉ : aucun writer existant ne l'appelle encore. Il ne remplace pas accountAdmission.js (garde actuelle, inchangée) ;
// l'intégration writer par writer relève des missions suivantes.
//
// Contrat : à appeler DANS la transaction du writer, avant toute écriture de celui-ci. Le helper ne fait que des lectures ;
// il retourne les écritures à ajouter (epoch+1 du tombstone en quarantaine) que le writer applique avec `applyTo(tx)`.
//
// Ordre de lecture (réserve C2, L0-F) : pour chaque partie, le tombstone est lu AVANT le profil, séquentiellement, et les parties
// sont traitées dans un ordre déterministe (identifiant puis collection). L0-F a mesuré dans l'émulateur que lire le profil avant
// le tombstone face à une quarantaine (qui lit le profil puis écrit tombstone et profil) provoque des blocages, alors que
// tombstone d'abord n'en a produit aucun (0/200). Ce choix n'a pas été validé contre Firestore réel.

const { STATE, OP_CLASS, readClosureState, closureRefusal } = require('./accountClosureState');

const TOMBSTONES = 'account_tombstones';
const validId = (id) => typeof id === 'string' && id.length > 0 && id.length <= 128 && !id.includes('/');

// parties : [{ collection, id, onClosed? }]. `onClosed: 'skip'` (bénéficiaire anonymisé ou absent, catégories B/C/D) laisse le
// writer poursuivre SANS écrire pour cette partie, et la retourne dans `skipped` pour que le writer trace le motif
// (`beneficiary_account_closed`) au lieu de créditer. Défaut : 'refuse'. Un bénéficiaire scellé est toujours refusé.
async function assertFinancialLock(tx, db, HttpsError, parties, opClass, { now = Date.now } = {}) {
  if (!Object.values(OP_CLASS).includes(opClass)) throw new TypeError(`Catégorie d'opération inconnue : ${opClass}`);
  if (!Array.isArray(parties) || parties.length === 0) throw new HttpsError('failed-precondition', 'Identite de commande invalide');

  const unique = new Map();
  for (const party of parties) {
    if (!party || !validId(party.collection) || !validId(party.id)) throw new HttpsError('failed-precondition', 'Identite de commande invalide');
    unique.set(`${party.collection}/${party.id}`, { collection: party.collection, id: party.id, onClosed: party.onClosed === 'skip' ? 'skip' : 'refuse' });
  }
  const ordered = [...unique.values()].sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : a.collection < b.collection ? -1 : a.collection > b.collection ? 1 : 0));

  const tombstones = new Map();
  const checked = [];
  const skipped = [];
  const writes = new Map();
  for (const party of ordered) {
    if (!tombstones.has(party.id)) {
      const ref = db.collection(TOMBSTONES).doc(party.id);
      tombstones.set(party.id, { ref, snap: await tx.get(ref) });
    }
    const profileSnap = await tx.get(db.collection(party.collection).doc(party.id));
    const { ref: tombstoneRef, snap: tombstoneSnap } = tombstones.get(party.id);
    const closure = readClosureState({
      tombstone: tombstoneSnap.exists ? tombstoneSnap.data() : null,
      profile: profileSnap.exists ? profileSnap.data() : null,
    });
    const refusal = closureRefusal(closure, opClass);
    if (refusal) {
      const closedBeneficiary = [STATE.ANONYMIZED, STATE.ABSENT].includes(closure.state);
      if (party.onClosed === 'skip' && opClass !== OP_CLASS.A && closedBeneficiary) {
        skipped.push({ collection: party.collection, id: party.id, state: closure.state, reason: 'beneficiary_account_closed' });
        continue;
      }
      throw new HttpsError('failed-precondition', refusal.message, { code: refusal.code });
    }
    checked.push({ collection: party.collection, id: party.id, state: closure.state, phase: closure.phase, epoch: closure.epoch });
    // B/C/D en quarantaine : l'epoch change dans la même transaction, ce qui invalide toute inspection de scellement antérieure.
    if (opClass !== OP_CLASS.A && closure.state === STATE.CLOSING && !writes.has(party.id)) {
      writes.set(party.id, { ref: tombstoneRef, data: { epoch: closure.epoch + 1, updatedAtMs: now() } });
    }
  }
  const plan = [...writes.values()];
  return {
    parties: checked,
    skipped,
    writes: plan,
    // À appeler par le writer APRÈS ses propres lectures, avec le même objet transactionnel.
    applyTo(writer) { for (const w of plan) writer.update(w.ref, w.data); },
  };
}

module.exports = { assertFinancialLock };
