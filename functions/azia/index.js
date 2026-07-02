'use strict';

const crypto = require('crypto');
const { getClient, MODEL, MAX_TOKENS, SYSTEM_PROMPT_BLOCKS } = require('./claudeClient');
const { getRecentMessages, appendMessage, clearHistory } = require('./conversationStore');
const { buildRegistry } = require('./toolRegistry');
const { buildConfirmAction, buildCleanupScheduler } = require('./pendingActions');

const MAX_MESSAGE_LENGTH = 2000;
const MAX_TOOL_TURNS     = 6; // plafond d'aller-retours outils par message utilisateur

// Factory : reçoit les dépendances déjà initialisées par functions/index.js
// (db, admin, onCall, onSchedule, checkRateLimit, logAudit, HttpsError) au
// lieu de les redéfinir — évite de dupliquer la logique de rate-limiting/audit
// existante.
module.exports = function createAzIa({
  db, admin, onCall, onSchedule, checkRateLimit, logAudit, HttpsError,
  axios, feexpayOperatorCode, FEEXPAY_TOKEN, FEEXPAY_API_URL, WEBHOOK_URL,
}) {

  const tools = buildRegistry({
    db, admin, logAudit, checkRateLimit, HttpsError,
    axios, feexpayOperatorCode, FEEXPAY_TOKEN, FEEXPAY_API_URL, WEBHOOK_URL,
  });
  const toolsByName = new Map(tools.map(t => [t.name, t]));
  const toolSchemas = tools.map(t => ({
    name:         t.name,
    description:  t.description,
    input_schema: t.input_schema,
  }));
  // Point de cache (prompt caching Anthropic) sur la dernière définition
  // d'outil — les schémas d'outils sont identiques à chaque appel, donc mis
  // en cache au même titre que SYSTEM_PROMPT_BLOCKS (voir claudeClient.js).
  if (toolSchemas.length > 0) {
    toolSchemas[toolSchemas.length - 1].cache_control = { type: 'ephemeral' };
  }

  // Exécute un outil et transforme toute erreur en résultat "is_error" pour
  // Claude plutôt que de faire échouer toute la requête — une commande
  // introuvable ou un solde inaccessible doit rester une réponse conversationnelle.
  async function executeTool(uid, name, input, conversationId) {
    const tool = toolsByName.get(name);
    if (!tool) {
      return { error: `Outil inconnu : ${name}` };
    }
    try {
      return await tool.handler(uid, input || {}, { conversationId });
    } catch (err) {
      return { error: err.message || 'Erreur inconnue' };
    }
  }

  // Journalisation best-effort de l'observabilité IA (Prompt 31) : rien ne
  // suivait jusqu'ici les outils utilisés, le nombre de tours, la latence ou
  // la consommation de tokens par conversation. Écrit dans `request_logs`
  // (même collection que le wrapper générique `withObservability`, Prompt
  // 25) avec des champs spécifiques IA en plus — pas une nouvelle collection,
  // et pas un simple retrofit du wrapper générique (qui ne capture pas
  // outils/tokens). Ne bloque jamais la réponse utilisateur.
  function logAiObservability(entry) {
    db.collection('request_logs').add({
      functionName: 'azIaChat',
      requestId:    crypto.randomUUID(),
      createdAt:    admin.firestore.FieldValue.serverTimestamp(),
      ...entry,
    }).catch((err) => console.error('request_logs (azIaChat) write failed:', err.message));
  }

  const azIaChat = onCall({
    region:         'europe-west1',
    timeoutSeconds: 120,
    memory:         '512MiB',
  }, async (request) => {
    if (!request.auth) {
      throw new HttpsError('unauthenticated', 'Vous devez être connecté');
    }
    const uid = request.auth.uid;
    const startTime = Date.now();

    const message = String(request.data?.message || '').trim();
    if (!message) {
      throw new HttpsError('invalid-argument', 'Message vide');
    }
    if (message.length > MAX_MESSAGE_LENGTH) {
      throw new HttpsError('invalid-argument', `Message trop long (${MAX_MESSAGE_LENGTH} caractères max)`);
    }

    await checkRateLimit(uid, 'ai_chat', 20, 60);

    let conversationId = request.data?.conversationId;
    if (!conversationId || typeof conversationId !== 'string') {
      conversationId = db.collection('ai_conversations').doc().id;
    }

    // L'historique persisté ne contient que les tours texte user/assistant
    // (pas les allers-retours tool_use/tool_result, qui restent internes à
    // cette invocation) — suffisant pour le contexte conversationnel futur,
    // sans avoir à rejouer la mécanique d'outils entre deux appels.
    const history  = await getRecentMessages(db, uid, conversationId);
    const messages = [...history, { role: 'user', content: message }];

    const anthropic = getClient();

    const toolsUsed = [];
    let turnsTaken       = 0;
    let inputTokens       = 0;
    let outputTokens      = 0;

    async function callClaude(withTools) {
      try {
        const response = await anthropic.messages.create({
          model:      MODEL,
          max_tokens: MAX_TOKENS,
          system:     SYSTEM_PROMPT_BLOCKS,
          messages,
          ...(withTools ? { tools: toolSchemas } : {}),
        });
        inputTokens  += response.usage?.input_tokens  || 0;
        outputTokens += response.usage?.output_tokens || 0;
        return response;
      } catch (err) {
        console.error('azIaChat Claude error:', err.message);
        throw new HttpsError('internal', "AZ IA rencontre un problème. Réessayez dans un instant.");
      }
    }

    let finalText  = null;
    let hitTurnCap = false;

    try {
      for (let turn = 0; turn < MAX_TOOL_TURNS; turn++) {
        turnsTaken = turn + 1;
        const response = await callClaude(true);
        messages.push({ role: 'assistant', content: response.content });

        const toolUseBlocks = response.content.filter(b => b.type === 'tool_use');
        if (toolUseBlocks.length === 0) {
          finalText = response.content
            .filter(b => b.type === 'text')
            .map(b => b.text)
            .join('\n')
            .trim();
          break;
        }

        const toolResults = [];
        for (const block of toolUseBlocks) {
          toolsUsed.push(block.name);
          const result = await executeTool(uid, block.name, block.input, conversationId);
          toolResults.push({
            type:        'tool_result',
            tool_use_id: block.id,
            content:     JSON.stringify(result),
            is_error:    !!(result && result.error),
          });
        }
        messages.push({ role: 'user', content: toolResults });

        if (turn === MAX_TOOL_TURNS - 1) {
          hitTurnCap = true;
        }
      }

      if (finalText === null) {
        // Plafond d'outils atteint sans réponse texte — un dernier appel sans
        // outils force une clôture en langage naturel plutôt qu'une boucle infinie.
        const closing = await callClaude(false);
        finalText = closing.content.filter(b => b.type === 'text').map(b => b.text).join('\n').trim();
      }
      finalText = finalText || "Désolé, je n'ai pas pu générer de réponse.";

      await appendMessage(db, admin, uid, conversationId, 'user', message);
      await appendMessage(db, admin, uid, conversationId, 'assistant', finalText);

      logAiObservability({
        userId: uid, status: 'success', durationMs: Date.now() - startTime,
        toolsUsed, turnCount: turnsTaken, inputTokens, outputTokens, hitTurnCap,
      });

      return { conversationId, reply: finalText, hitTurnCap };
    } catch (err) {
      logAiObservability({
        userId: uid, status: 'error', durationMs: Date.now() - startTime,
        toolsUsed, turnCount: turnsTaken, inputTokens, outputTokens,
        errorCode: err.code || 'internal', errorMessage: err.message || null,
      });
      throw err;
    }
  });

  const aiConfirmAction = buildConfirmAction({ db, admin, onCall, logAudit, HttpsError, toolsByName });
  const aiCleanupExpiredPendingActions = buildCleanupScheduler({ db, admin, onSchedule });

  // Contrôle utilisateur sur son historique de conversation (Prompt 33) —
  // ai_conversations n'était jamais géré/effacé nulle part avant ce jour.
  const clearAiHistory = onCall(async (request) => {
    if (!request.auth) {
      throw new HttpsError('unauthenticated', 'Vous devez être connecté');
    }
    const uid = request.auth.uid;
    await checkRateLimit(uid, 'clear_ai_history', 5, 3600);

    const deletedCount = await clearHistory(db, uid);
    await logAudit({
      userId: uid, userType: 'client', action: 'clear_ai_history',
      metadata: { deletedCount },
    });

    return { success: true, deletedCount };
  });

  return { azIaChat, aiConfirmAction, aiCleanupExpiredPendingActions, clearAiHistory };
};
