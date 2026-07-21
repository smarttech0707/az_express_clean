'use strict';

// ═══════════════════════════════════════════════════════════════════════════
// Rappels AZ IA (Master Prompt 118) — nouvelle collection `ai_reminders`,
// CF-only en écriture (comme toutes les collections `ai_*`). Non financier,
// non destructeur : créer un rappel ne mute rien d'autre que ce document,
// donc pas de confirmation serveur requise (cohérent avec create_support_ticket,
// remember_user_info — outils similaires déjà sans confirmation).
// L'envoi effectif (push FCM à l'échéance) est fait par le scheduler
// `functions/azia/reminderScheduler.js`, pas par cet outil.
// ═══════════════════════════════════════════════════════════════════════════

const VALID_TYPES = ['payer', 'recharger', 'acheter', 'medicament', 'livraison', 'visite', 'autre'];
const MAX_MINUTES_AHEAD = 30 * 24 * 60; // 30 jours — borne large mais pas illimitée
const DEFAULT_MINUTES_AHEAD = 24 * 60;  // repli si ni inMinutes ni atIso n'est exploitable

function createReminder({ db, admin }) {
  return {
    name: 'create_reminder',
    description: "Crée un rappel pour l'utilisateur (payer, recharger le wallet, acheter, prendre un médicament, livraison, visite immobilière...). Utilise `atIso` si l'utilisateur donne une date/heure précise, sinon `inMinutes` pour un délai relatif (ex: \"dans 2 heures\" -> 120, \"demain\" -> 1440).",
    input_schema: {
      type: 'object',
      properties: {
        type:      { type: 'string', enum: VALID_TYPES, description: 'Catégorie du rappel.' },
        message:   { type: 'string', description: 'Texte du rappel (ex: "Recharger le wallet avant la commande de demain").' },
        inMinutes: { type: 'number', description: "Délai en minutes avant l'échéance (ex: 120 pour \"dans 2 heures\")." },
        atIso:     { type: 'string', description: 'Date/heure ISO 8601 précise si connue (ex: "2026-07-15T09:00:00.000Z").' },
      },
      required: ['type', 'message'],
    },
    handler: async (uid, input) => {
      const type = VALID_TYPES.includes(input?.type) ? input.type : 'autre';
      const message = String(input?.message || '').trim();
      if (!message) throw new Error('Le texte du rappel est requis.');

      let dueAtMs = null;
      if (input?.atIso) {
        const parsed = Date.parse(String(input.atIso));
        if (!Number.isNaN(parsed) && parsed > Date.now()) dueAtMs = parsed;
      }
      if (dueAtMs === null && typeof input?.inMinutes === 'number' && input.inMinutes > 0) {
        const clamped = Math.min(input.inMinutes, MAX_MINUTES_AHEAD);
        dueAtMs = Date.now() + clamped * 60 * 1000;
      }
      if (dueAtMs === null) {
        dueAtMs = Date.now() + DEFAULT_MINUTES_AHEAD * 60 * 1000;
      }

      const ref = db.collection('ai_reminders').doc();
      await ref.set({
        uid, type, message,
        status:    'pending',
        dueAt:     admin.firestore.Timestamp.fromMillis(dueAtMs),
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });

      return { reminderId: ref.id, dueAtIso: new Date(dueAtMs).toISOString() };
    },
  };
}

module.exports = { createReminder, VALID_TYPES };
