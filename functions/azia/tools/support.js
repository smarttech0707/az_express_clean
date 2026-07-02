'use strict';

// Mêmes catégories que lib/screens/support/support_screen.dart
const VALID_CATEGORIES = ['Livraison', 'Paiement / Wallet', 'Commande', 'Compte', 'E-Kbine', 'Marketplace', 'Autre'];

function createSupportTicket({ db, admin, logAudit }) {
  return {
    name: 'create_support_ticket',
    description: "Crée un ticket de support pour l'utilisateur lorsqu'AZ IA ne peut pas résoudre son problème seul.",
    input_schema: {
      type: 'object',
      properties: {
        subject:  { type: 'string', description: 'Résumé court du problème.' },
        message:  { type: 'string', description: 'Description détaillée du problème.' },
        category: { type: 'string', enum: VALID_CATEGORIES, description: 'Catégorie du ticket.' },
      },
      required: ['subject', 'message'],
    },
    handler: async (uid, input) => {
      const subject  = String(input?.subject || '').trim();
      const message  = String(input?.message || '').trim();
      const category = VALID_CATEGORIES.includes(input?.category) ? input.category : 'Autre';

      if (!subject || !message) {
        throw new Error('Le sujet et le message du ticket sont requis.');
      }

      const ref = await db.collection('support_tickets').add({
        userId:        uid,
        subject,
        message,
        category,
        status:        'open',
        screenshotUrl: null,
        source:        'ai_chat',
        createdAt:     admin.firestore.FieldValue.serverTimestamp(),
        messages: [
          { sender: 'user', text: message, timestamp: new Date().toISOString() },
        ],
      });

      await logAudit({
        userId:   uid,
        userType: 'client',
        action:   'ai_create_support_ticket',
        targetId: ref.id,
        status:   'success',
        metadata: { source: 'ai_chat', category },
      });

      return { ticketId: ref.id, message: 'Ticket créé avec succès.' };
    },
  };
}

module.exports = { createSupportTicket };
