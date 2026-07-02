'use strict';

const HISTORY_LIMIT = 40;

async function getRecentMessages(db, uid, conversationId, limit = HISTORY_LIMIT) {
  const snap = await db.collection('ai_conversations').doc(uid)
    .collection('messages')
    .where('conversationId', '==', conversationId)
    .orderBy('createdAt', 'asc')
    .limitToLast(limit)
    .get();

  return snap.docs.map(d => {
    const data = d.data();
    return { role: data.role, content: data.content };
  });
}

async function appendMessage(db, admin, uid, conversationId, role, content) {
  await db.collection('ai_conversations').doc(uid)
    .collection('messages')
    .add({
      conversationId,
      role,
      content,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });
}

// Supprime tout l'historique de conversation d'un utilisateur — trouvaille
// du Prompt 33 : ai_conversations n'était jamais lu ni géré directement par
// le client, donc l'utilisateur n'avait aucun contrôle sur cette mémoire
// pourtant déjà réelle. Boucle par lots de 500 (limite Firestore par batch)
// tant qu'il reste des messages à effacer.
async function clearHistory(db, uid) {
  const messagesRef = db.collection('ai_conversations').doc(uid).collection('messages');
  let deletedCount = 0;

  while (true) {
    const snap = await messagesRef.limit(500).get();
    if (snap.empty) break;

    const batch = db.batch();
    snap.docs.forEach((doc) => batch.delete(doc.ref));
    await batch.commit();
    deletedCount += snap.size;

    if (snap.size < 500) break;
  }

  return deletedCount;
}

module.exports = { getRecentMessages, appendMessage, clearHistory };
