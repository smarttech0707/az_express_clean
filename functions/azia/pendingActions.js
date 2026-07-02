'use strict';

// 5 minutes pour toutes les actions (décision validée avec l'utilisateur —
// pas de durée différenciée par type d'action).
const DEFAULT_EXPIRY_MS = 5 * 60 * 1000;

// Un outil sensible (financier/destructeur) appelle ceci au lieu de muter
// directement — l'utilisateur doit confirmer via aiConfirmAction avant que
// la vraie mutation n'ait lieu.
async function createPendingAction(db, admin, { uid, conversationId, toolName, toolInput, summaryFr, amount }) {
  const ref = db.collection('ai_pending_actions').doc();
  await ref.set({
    uid,
    conversationId: conversationId || null,
    toolName,
    toolInput:      toolInput || {},
    summaryFr,
    amount:         typeof amount === 'number' ? amount : null,
    status:         'pending',
    createdAt:      admin.firestore.FieldValue.serverTimestamp(),
    expiresAt:      admin.firestore.Timestamp.fromMillis(Date.now() + DEFAULT_EXPIRY_MS),
  });
  return ref.id;
}

// aiConfirmAction (onCall) — un seul export pour confirmer OU annuler une
// action en attente. `toolsByName` doit être le même registre que celui
// utilisé par azIaChat pour exécuter les outils : seul un outil exposant un
// `confirmHandler` peut être confirmé. La bascule de statut se fait dans la
// même transaction que la mutation réelle — même schéma que
// `ekClientConfirmOrder` dans functions/index.js — pour empêcher un replay
// (un double-tap voit status !== 'pending' et échoue proprement).
function buildConfirmAction({ db, admin, onCall, logAudit, HttpsError, toolsByName }) {
  return onCall({
    region:         'europe-west1',
    timeoutSeconds: 60,
    memory:         '256MiB',
  }, async (request) => {
    if (!request.auth) {
      throw new HttpsError('unauthenticated', 'Vous devez être connecté');
    }
    const uid      = request.auth.uid;
    const actionId = String(request.data?.actionId || '');
    const decision = request.data?.decision === 'cancel' ? 'cancel' : 'confirm';

    if (!actionId) {
      throw new HttpsError('invalid-argument', 'actionId manquant');
    }

    const ref = db.collection('ai_pending_actions').doc(actionId);

    if (decision === 'cancel') {
      await db.runTransaction(async (tx) => {
        const snap = await tx.get(ref);
        if (!snap.exists) throw new HttpsError('not-found', 'Action introuvable');
        const data = snap.data();
        if (data.uid !== uid) throw new HttpsError('permission-denied', 'Non autorisé');
        if (data.status !== 'pending') throw new HttpsError('failed-precondition', 'Cette action a déjà été traitée');
        tx.update(ref, { status: 'cancelled', resolvedAt: admin.firestore.FieldValue.serverTimestamp() });
      });
      return { status: 'cancelled' };
    }

    const outcome = await db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      if (!snap.exists) throw new HttpsError('not-found', 'Action introuvable');
      const data = snap.data();
      if (data.uid !== uid) throw new HttpsError('permission-denied', 'Non autorisé');
      if (data.status !== 'pending') throw new HttpsError('failed-precondition', 'Cette action a déjà été traitée');

      const expiresAtMs = data.expiresAt?.toMillis ? data.expiresAt.toMillis() : 0;
      if (expiresAtMs < Date.now()) {
        tx.update(ref, { status: 'expired', resolvedAt: admin.firestore.FieldValue.serverTimestamp() });
        throw new HttpsError('deadline-exceeded', 'Cette action a expiré. Recommencez la demande.');
      }

      const tool = toolsByName.get(data.toolName);
      if (!tool || typeof tool.confirmHandler !== 'function') {
        throw new HttpsError('failed-precondition', "Cette action n'est plus prise en charge.");
      }

      const result = await tool.confirmHandler(tx, uid, data.toolInput || {});
      tx.update(ref, { status: 'completed', resolvedAt: admin.firestore.FieldValue.serverTimestamp() });
      return { toolName: data.toolName, amount: data.amount, result };
    });

    // Étape optionnelle, hors transaction : un outil comme la recharge
    // wallet doit appeler une API externe (FeexPay) après la bascule de
    // statut — jamais à l'intérieur d'une transaction Firestore, qui peut
    // être retentée par le SDK et rejouerait l'appel réseau.
    let finalResult = outcome.result;
    const tool = toolsByName.get(outcome.toolName);
    if (tool && typeof tool.afterConfirm === 'function') {
      try {
        finalResult = await tool.afterConfirm(uid, finalResult);
      } catch (err) {
        console.error(`aiConfirmAction afterConfirm error (${outcome.toolName}):`, err.message);
        finalResult = { ...finalResult, afterConfirmError: err.message };
      }
    }

    await logAudit({
      userId:   uid,
      userType: 'client',
      action:   `ai_confirm_${outcome.toolName}`,
      targetId: actionId,
      amount:   outcome.amount,
      status:   'success',
      metadata: { source: 'ai_chat' },
    });

    return { status: 'completed', ...finalResult };
  });
}

// Même famille que autoExpireOrders/cleanupExpiredRateLimits déjà présents
// dans functions/index.js — nettoie les actions jamais confirmées.
function buildCleanupScheduler({ db, admin, onSchedule }) {
  return onSchedule({
    schedule:       'every 10 minutes',
    timeoutSeconds: 120,
    memory:         '256MiB',
    region:         'europe-west1',
  }, async () => {
    const now  = admin.firestore.Timestamp.now();
    const snap = await db.collection('ai_pending_actions')
      .where('status', '==', 'pending')
      .where('expiresAt', '<', now)
      .get();
    if (snap.empty) return;

    const batch = db.batch();
    snap.docs.forEach(doc => {
      batch.update(doc.ref, { status: 'expired', resolvedAt: admin.firestore.FieldValue.serverTimestamp() });
    });
    await batch.commit();
    console.log(`🧹 Actions IA expirées : ${snap.size} documents mis à jour`);
  });
}

module.exports = { createPendingAction, buildConfirmAction, buildCleanupScheduler, DEFAULT_EXPIRY_MS };
