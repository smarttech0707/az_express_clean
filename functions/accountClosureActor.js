'use strict';

// L3 : exceptions contrôlées pour les opérations DÉJÀ ENGAGÉES (protocole 2D-2A.3 §4, décisions D6-a/b/c, DR1-DR3, X-2).
// Un compte en quarantaine (tombstone `phase` absente ou `closing`) peut terminer, et seulement terminer, une opération engagée
// avant la quarantaine, par exactement cinq fonctions. Rien n'autorise globalement un utilisateur en quarantaine : le tombstone
// n'est jamais levé ni supprimé, un compte scellé / anonymisé / absent / illisible n'a aucune exception.

const { STATE, OP_CLASS, readClosureState, closureRefusal } = require('./accountClosureState');

const TOMBSTONES = 'account_tombstones';

// Liste FERMÉE : fonction -> collection du rôle de l'acteur (client ou livreur lié à la commande).
const CLOSURE_EXCEPTIONS = Object.freeze({
  payOrderFromWalletCF: 'clients',
  cancelOrderCF: 'clients',
  deliverOrderCF: 'livreurs',
  confirmOrderDeliveryWithProof: 'livreurs',
  ekClientConfirmOrder: 'clients',
});

// État lisible du bénéficiaire refusé (details.cause) à partir du code de refus de accountClosureState.
const IN_PROGRESS = 'ACCOUNT_DELETION_IN_PROGRESS';
const BENEFICIARY_CLOSED = 'BENEFICIARY_ACCOUNT_CLOSED';
const NOT_ENGAGED = 'ACCOUNT_CLOSING_OPERATION_NOT_ENGAGED';
// Motifs de mise en revue d'une commande (orders.reviewReason). REFUSED verrouille pay/deliver jusqu'à clearBeneficiaryReview ;
// OMITTED signale un crédit non versé (somme due, conservée côté AZ) et n'est PAS levable par clearBeneficiaryReview.
const REVIEW_REASON = Object.freeze({ REFUSED: 'beneficiary_closed', OMITTED: 'beneficiary_credit_omitted' });

// Horodatage tolérant (Timestamp Admin, {seconds}, millisecondes). Absent ou invalide => null (refus).
function toMillis(v) {
  if (v === null || v === undefined) return null;
  if (typeof v === 'number') return Number.isFinite(v) && v > 0 ? v : null;
  if (typeof v.toMillis === 'function') { const m = v.toMillis(); return Number.isFinite(m) && m > 0 ? m : null; }
  const s = v.seconds ?? v._seconds;
  if (Number.isFinite(s) && s > 0) return s * 1000 + Math.floor((v.nanoseconds ?? v._nanoseconds ?? 0) / 1e6);
  return null;
}

const denied = (HttpsError, code, message) => new HttpsError('permission-denied', message, { code });

// Garde de l'acteur, à appeler DANS la transaction, avant toute écriture. Ordre de lecture : tombstone puis profil (C2/L0-F).
// engagedAtMs : instant (ms) où l'opération a été engagée, lu sur la commande ; exigé seulement en quarantaine.
async function assertClosureActor(tx, db, HttpsError, { fn, uid, engagedAtMs = null, now = Date.now }) {
  const collection = CLOSURE_EXCEPTIONS[fn];
  if (!collection) throw new TypeError(`Fonction sans exception de fermeture : ${fn}`);
  if (typeof uid !== 'string' || !uid || uid.includes('/')) throw denied(HttpsError, IN_PROGRESS, 'Compte supprime ou en cours de suppression');
  const tombRef = db.collection(TOMBSTONES).doc(uid);
  const tombSnap = await tx.get(tombRef);
  const profileSnap = await tx.get(db.collection(collection).doc(uid));
  const tomb = tombSnap.exists ? tombSnap.data() : null;
  const closure = readClosureState({ tombstone: tomb, profile: profileSnap.exists ? profileSnap.data() : null });
  // Aucun tombstone ET aucun profil : pas une fermeture (rien à protéger ici). Le writer applique ses propres contrôles historiques
  // (solde nul, profil requis...) ; seul l'anonymisation (isDeleted) ou un tombstone déclenche le refus de fermeture.
  if (closure.state === STATE.ABSENT) return { state: closure.state, writes: [], applyTo() {} };
  const refusal = closureRefusal(closure, OP_CLASS.B);
  if (refusal) throw denied(HttpsError, IN_PROGRESS, refusal.message);
  let writes = [];
  if (closure.state === STATE.CLOSING) {
    // DR3 / C5 : un tombstone sans profil (profil supprimé) n'ouvre aucune exception.
    if (!profileSnap.exists) throw denied(HttpsError, IN_PROGRESS, 'Compte supprime ou en cours de suppression');
    if (closure.deleting || closure.authDeleted) throw denied(HttpsError, IN_PROGRESS, 'Compte supprime ou en cours de suppression');
    const quarantinedAt = toMillis(tomb && tomb.createdAt);
    if (engagedAtMs === null || engagedAtMs === undefined || quarantinedAt === null || engagedAtMs >= quarantinedAt) {
      throw new HttpsError('failed-precondition', 'Operation non engagee avant la suppression du compte', { code: NOT_ENGAGED });
    }
    writes = [{ ref: tombRef, data: { epoch: closure.epoch + 1, updatedAtMs: now() } }];
  }
  return { state: closure.state, writes, applyTo(writer) { for (const w of writes) writer.update(w.ref, w.data); } };
}

// Acteur + bénéficiaires (catégorie B ou C). Bénéficiaire refusé (anonymisé, absent, scellé, illisible) => refus global
// BENEFICIARY_ACCOUNT_CLOSED sans écriture ; 'skip' (annulation, DR1) le laisse en `skipped`. Retourne applyTo pour l'epoch.
// L4 — politique par bénéficiaire (décisions confirmées, choix A). La quarantaine concerne le DESTINATAIRE du crédit :
//   actif / suppression demandée        : l'effet s'applique.
//   quarantaine simple (tombstone closing) : aucun NOUVEAU crédit tant que le dossier n'est pas résolu. `onQuarantine` :
//        'skip'   le crédit est omis, la somme reste côté AZ (déjà prélevée) et le dossier est signalé (montant dû tracé) ;
//        'refuse' toute l'opération est refusée sans écriture (la somme n'est pas encore prélevée : aucun mécanisme de retenue sûr) ;
//        'apply'  l'effet s'applique (DÉBIT d'un compte en restitution) et l'epoch du tombstone passe à +1.
//   scellé (ou suppression Auth commencée) / anonymisé / absent : aucune opération financière sur ce compte. `onClosed` :
//        'skip' (omission signalée) ou 'refuse' (défaut). Jamais un profil absent pris pour un profil actif.
//   tombstone illisible : toujours refusé (une lecture douteuse n'autorise jamais un crédit). Une erreur de lecture se propage.
// Chaque bénéficiaire est examiné séparément (ordre déterministe, tombstone puis profil) pour nommer la partie et son état.
async function resolveParty(tx, db, party) {
  const tombRef = db.collection(TOMBSTONES).doc(party.id);
  const tombSnap = await tx.get(tombRef);
  const profileSnap = await tx.get(db.collection(party.collection).doc(party.id));
  const closure = readClosureState({ tombstone: tombSnap.exists ? tombSnap.data() : null, profile: profileSnap.exists ? profileSnap.data() : null });
  let state = closure.state;
  if (state === STATE.CLOSING && (closure.deleting || closure.authDeleted)) state = STATE.SEALED;
  return { state, epoch: closure.epoch, tombRef };
}

// Lecture seule (aucune écriture) : le bénéficiaire peut-il être crédité MAINTENANT ? Même lecture que closureGuard (tombstone puis
// profil). Sert aux contrôles administratifs (levée d'un refus) qui ne doivent jamais deviner l'état d'un compte.
async function isBeneficiaryCreditable(tx, db, party) {
  const { state } = await resolveParty(tx, db, party);
  return state === STATE.ACTIVE || state === STATE.DELETION_REQUESTED;
}

// L4.2 — confirmation ADMINISTRATIVE : l'acteur est un super-admin (aucun contrôle d'acteur de fermeture), mais chaque compte qui
// recevrait un crédit doit être créditable À CE MOMENT, lu dans la transaction (un tombstone créé ensuite invalide la transaction,
// qui est rejouée et refuse). Aucune omission, aucune retenue, aucune application : quarantaine, scellé, anonymisé, absent ou
// illisible => refus de toute l'opération. Lectures uniquement.
async function assertBeneficiariesCreditable(tx, db, HttpsError, beneficiaries = []) {
  const unique = new Map();
  for (const b of beneficiaries) if (b) unique.set(`${b.collection}/${b.id}`, b);
  const sorted = [...unique.values()].sort((a, b) => (a.collection < b.collection ? -1 : a.collection > b.collection ? 1 : a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
  for (const party of sorted) {
    const { state } = await resolveParty(tx, db, party);
    if (state !== STATE.ACTIVE && state !== STATE.DELETION_REQUESTED) {
      throw new HttpsError('failed-precondition', `${BENEFICIARY_CLOSED}: operation suspendue`,
        { code: BENEFICIARY_CLOSED, cause: state, collection: party.collection, id: party.id });
    }
  }
}

async function closureGuard(tx, db, HttpsError, { fn, uid, engagedAtMs, beneficiaries = [], now = Date.now }) {
  const actor = await assertClosureActor(tx, db, HttpsError, { fn, uid, engagedAtMs, now });
  const unique = new Map();
  for (const b of beneficiaries) if (b && b.id !== uid) unique.set(`${b.collection}/${b.id}`, b);
  const others = [...unique.values()].sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : a.collection < b.collection ? -1 : a.collection > b.collection ? 1 : 0));
  const skipped = [];
  const writes = [];
  const refuse = (party, state) => new HttpsError('failed-precondition', `${BENEFICIARY_CLOSED}: operation suspendue`,
    { code: BENEFICIARY_CLOSED, cause: state, collection: party.collection, id: party.id });
  for (const party of others) {
    const { state, epoch, tombRef } = await resolveParty(tx, db, party);
    const note = (reason) => skipped.push({ collection: party.collection, id: party.id, state, reason, amount: party.amount ?? null });
    if (state === STATE.ACTIVE || state === STATE.DELETION_REQUESTED) continue;
    if (state === STATE.UNREADABLE) throw refuse(party, state);
    if (state === STATE.CLOSING) {
      const mode = party.onQuarantine || 'refuse';
      if (mode === 'apply') writes.push({ ref: tombRef, data: { epoch: epoch + 1, updatedAtMs: now() } });
      else if (mode === 'skip') note('beneficiary_in_quarantine');
      else throw refuse(party, state);
      continue;
    }
    if ((party.onClosed || 'refuse') === 'skip') note('beneficiary_account_closed');
    else throw refuse(party, state);
  }
  return { state: actor.state, skipped, applyTo(writer) { actor.applyTo(writer); for (const w of writes) writer.update(w.ref, w.data); } };
}

// Une commande dont un refus pour bénéficiaire fermé est en revue ne se règle plus ni ne se livre (hors confirmation
// administrative) tant que clearBeneficiaryReview ne l'a pas levée.
function assertNotUnderReview(HttpsError, order) {
  if (order && order.needsReview === true && order.reviewReason === REVIEW_REASON.REFUSED) {
    throw new HttpsError('failed-precondition', 'ORDER_UNDER_REVIEW: commande en revue administrative', { code: 'ORDER_UNDER_REVIEW' });
  }
}

// L4.6 : champs plats ADDITIFS d'un signalement (clientId / driverId / sellerId / pharmacieId / partnerId), pour que l'inspecteur du
// moteur d'obligations (requêtes par champ propriétaire) retrouve le signalement. La source de vérité reste la structure imbriquée
// (`parties[]` / `beneficiary`) ; le moteur exige que les champs plats la confirment. Deux bénéficiaires d'un même champ => champ omis.
const FLAT_KEY_BY_COLLECTION = Object.freeze({ clients: 'clientId', livreurs: 'driverId', sellers: 'sellerId', pharmacies: 'pharmacieId', restaurants: 'partnerId', boulangeries: 'partnerId' });
function flagPartyFields(parties) {
  const byKey = {};
  for (const p of parties || []) {
    const key = p && FLAT_KEY_BY_COLLECTION[p.collection];
    if (key && typeof p.id === 'string' && p.id) (byKey[key] = byKey[key] || new Set()).add(p.id);
  }
  const out = {};
  for (const [key, ids] of Object.entries(byKey)) if (ids.size === 1) out[key] = [...ids][0];
  return out;
}

const REFUSAL_KIND = Object.freeze({ payOrderFromWalletCF: 'pay', cancelOrderCF: 'cancel', deliverOrderCF: 'deliver', confirmOrderDeliveryWithProof: 'deliver' });

// Trace idempotente d'un refus pour bénéficiaire fermé (D6-a). Exécutée APRÈS l'échec de la transaction (qui n'a rien écrit) :
// aucun effet financier, aucune donnée personnelle (identifiants techniques, état, motif). Document déterministe par opération :
// un retry ne crée rien de plus. N'est PAS un signalement de paiement réussi (type distinct, `completed:false`).
// Met aussi la commande en revue (needsReview) de façon idempotente, sans toucher à son statut.
async function recordBeneficiaryRefusal(db, admin, { fn, orderId, details }) {
  try {
    const kind = REFUSAL_KIND[fn] || 'deliver';
    const flagId = `${orderId}_${kind}_beneficiary_refused`;
    const ref = db.collection('reconciliation_flags').doc(flagId);
    let created = false;
    if (!(await ref.get()).exists) {
      await ref.set({
        orderId, type: 'beneficiary_closed_refused', operation: fn, status: 'open', needsReview: true, completed: false,
        beneficiary: { collection: details.collection || null, id: details.id || null, state: details.cause || null },
        ...flagPartyFields([{ collection: details.collection, id: details.id }]),
        createdAtMs: Date.now(),
      });
      created = true;
    }
    const orderRef = db.collection('orders').doc(orderId);
    const order = await orderRef.get();
    if (order.exists && order.data().needsReview !== true) {
      await orderRef.update({ needsReview: true, reviewReason: REVIEW_REASON.REFUSED, reviewFlagId: flagId });
    }
    return created;
  } catch (_) {
    return false; // la trace ne doit jamais masquer le refus métier
  }
}

// Exécute la transaction d'un writer et trace le refus « bénéficiaire fermé » (puis relance l'erreur, inchangée).
async function withRefusalTrace(db, admin, { fn, orderId }, run) {
  try {
    return await run();
  } catch (e) {
    if (e && e.details && e.details.code === BENEFICIARY_CLOSED) await recordBeneficiaryRefusal(db, admin, { fn, orderId, details: e.details });
    throw e;
  }
}

// Enveloppe `onCall` des cinq fonctions : identique à `onCall` d'index.js SANS le refus du wrapper pour tout tombstone.
// Contrôle préalable hors transaction (rapide) : tombstone absent, ou en quarantaine simple. Le contrôle décisif est refait
// dans la transaction par assertClosureActor.
function buildOnCallClosing({ rawOnCall, db, HttpsError }) {
  return function onCallClosing(fn, options, handler) {
    if (!CLOSURE_EXCEPTIONS[fn]) throw new TypeError(`onCallClosing : fonction non autorisee ${fn}`);
    if (typeof options === 'function') { handler = options; options = {}; }
    return rawOnCall(options, async (request, ...rest) => {
      const uid = request.auth && request.auth.uid;
      if (uid) {
        const snap = await db.collection(TOMBSTONES).doc(uid).get();
        if (snap.exists) {
          const closure = readClosureState({ tombstone: snap.data(), profile: { } });
          if (closure.state !== STATE.CLOSING || closure.deleting || closure.authDeleted) {
            throw denied(HttpsError, IN_PROGRESS, 'Compte supprime ou en cours de suppression');
          }
        }
      }
      return handler(request, ...rest);
    });
  };
}

module.exports = { CLOSURE_EXCEPTIONS, assertClosureActor, closureGuard, assertBeneficiariesCreditable, isBeneficiaryCreditable, recordBeneficiaryRefusal, withRefusalTrace, flagPartyFields, assertNotUnderReview, REVIEW_REASON, buildOnCallClosing, toMillis, BENEFICIARY_CLOSED, NOT_ENGAGED };
