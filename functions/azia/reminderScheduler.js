'use strict';

// Envoi effectif des rappels arrivés à échéance (Master Prompt 118) — même
// famille que `autoExpireOrders`/`cleanupExpiredRateLimits`/
// `aiCleanupExpiredPendingActions` déjà présents : un scheduler qui balaie
// une collection sur un critère de temps. Nécessite le jeton FCM du client
// (`clients/{uid}.fcmToken`, déjà utilisé partout ailleurs pour les push) —
// silencieusement ignoré si absent, jamais une erreur bloquante.
function buildReminderScheduler({ db, admin, onSchedule, sendToToken }) {
  return onSchedule({
    schedule:       'every 15 minutes',
    timeoutSeconds: 120,
    memory:         '256MiB',
    region:         'europe-west1',
    // Master Prompt 122 — quota CPU Cloud Run régional : voir même
    // justification que buildCleanupScheduler (pendingActions.js). Ce
    // scheduler n'avait auparavant AUCUNE limite explicite (maxInstances
    // retombait sur le défaut Cloud Run, non plafonné dans le code) —
    // corrigé en plus de la réduction de coût.
    maxInstances:   1,
    cpu:            0.5,
  }, async () => {
    const now = admin.firestore.Timestamp.now();
    const snap = await db.collection('ai_reminders')
      .where('status', '==', 'pending')
      .where('dueAt', '<=', now)
      .limit(200)
      .get();
    if (snap.empty) return;

    for (const doc of snap.docs) {
      const reminder = doc.data();
      try {
        const clientSnap = await db.collection('clients').doc(reminder.uid).get();
        const token = clientSnap.exists ? clientSnap.data().fcmToken : null;
        if (token) {
          await sendToToken(token, 'AZ Express — Rappel', reminder.message, {
            type: 'ai_reminder', reminderId: doc.id,
          });
        }
        await doc.ref.update({ status: 'sent', sentAt: admin.firestore.FieldValue.serverTimestamp() });
      } catch (err) {
        console.error(`reminderScheduler: échec pour ${doc.id}:`, err.message);
        // Laissé en 'pending' — sera retenté à la prochaine exécution (15 min
        // plus tard) plutôt que marqué en échec définitif sur une panne
        // transitoire (FCM temporairement indisponible, etc.).
      }
    }
    console.log(`🔔 Rappels traités : ${snap.size}`);
  });
}

module.exports = { buildReminderScheduler };
