'use strict';

const crypto = require('crypto');
const { SYSTEM_PROMPT } = require('./systemPrompt');
const { textBlock, toolResultBlock } = require('./canonicalHistory');
const { createToolExecutionLedger } = require('./toolExecutionLedger');
const { createPersistentToolLedger, isPersistentTool } = require('./persistentToolLedger');
const MAX_TOKENS = 1024;
const { getRecentMessages, appendMessage, clearHistory } = require('./conversationStore');
const { buildRegistry } = require('./toolRegistry');
const { buildConfirmAction, buildCleanupScheduler } = require('./pendingActions');
const { createAIProviderService } = require('./AIProviderService');
const { createPolicyEngine } = require('./policyEngine');
const { createAiGateway } = require('./aiGateway');
const { buildUserContext } = require('./contextBuilder');
const { buildTurnResponse } = require('./responseBuilder');
const { buildReminderScheduler } = require('./reminderScheduler');

const MAX_MESSAGE_LENGTH = 2000;
const MAX_TOOL_TURNS     = 6; // plafond d'aller-retours outils par message utilisateur
const MAX_IMAGE_BASE64_LENGTH = 6 * 1024 * 1024; // ~4.5 Mo réels une fois décodé, marge sous la limite Anthropic (5 Mo)
const ALLOWED_IMAGE_MEDIA_TYPES = ['image/jpeg', 'image/png', 'image/webp', 'image/gif'];

// Factory : reçoit les dépendances déjà initialisées par functions/index.js
// (db, admin, onCall, onSchedule, checkRateLimit, logAudit, HttpsError) au
// lieu de les redéfinir — évite de dupliquer la logique de rate-limiting/audit
// existante. `sendToToken` ajouté (Master Prompt 118) pour le scheduler de
// rappels — même helper FCM déjà utilisé partout ailleurs dans l'app.
module.exports = function createAzIa({
  db, admin, onCall, onSchedule, checkRateLimit, logAudit, HttpsError,
  axios, feexpayOperatorCode, FEEXPAY_TOKEN, FEEXPAY_API_URL, WEBHOOK_URL,
  azIaChatSecrets = [], aiConfirmActionSecrets = [],
  sendToToken, providers,
}) {

  const aiProviderService = createAIProviderService({ db, admin, providers });

  const tools = buildRegistry({
    db, admin, logAudit, checkRateLimit, HttpsError,
    axios, feexpayOperatorCode, FEEXPAY_TOKEN, FEEXPAY_API_URL, WEBHOOK_URL,
  });
  const policyEngine = createPolicyEngine({ tools });
  const aiGateway = createAiGateway({ providerService: aiProviderService, policyEngine });
  const toolsByName = new Map(tools.map(t => [t.name, t]));
  const toolSchemas = policyEngine.getToolSchemas();
  async function executeTool(uid, name, input, conversationId) {
    const config = await aiProviderService.getConfig();
    if (!policyEngine.canExecute(name, config)) {
      return { error: `Outil non autorise : ${name}` };
    }
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
    secrets:        azIaChatSecrets,
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

    // Images stay in the same canonical history as text and tool results.
    let imageBlock = null;
    const imageBase64 = request.data?.imageBase64;
    if (imageBase64) {
      const mediaType = String(request.data?.imageMediaType || 'image/jpeg').toLowerCase();
      if (!ALLOWED_IMAGE_MEDIA_TYPES.includes(mediaType)) {
        throw new HttpsError('invalid-argument', 'Format image non supporté (jpeg, png, webp ou gif).');
      }
      if (String(imageBase64).length > MAX_IMAGE_BASE64_LENGTH) {
        throw new HttpsError('invalid-argument', 'Image trop volumineuse.');
      }
      imageBlock = { type: 'image', mediaType, data: String(imageBase64) };
    }

    // Localisation GPS (Master Prompt 113, section 3) — transmise par le
    // client uniquement si déjà autorisée côté app ; jamais demandée par ce
    // endpoint lui-même. Reste optionnelle et best-effort, comme tout le
    // reste du contexte injecté par buildUserContext().
    const location = request.data?.location;
    const safeLocation = (location && typeof location.latitude === 'number' && typeof location.longitude === 'number')
      ? { latitude: location.latitude, longitude: location.longitude, address: location.address ? String(location.address).slice(0, 200) : null }
      : null;

    await checkRateLimit(uid, 'ai_chat', 20, 60);

    let conversationId = request.data?.conversationId;
    if (!conversationId || typeof conversationId !== 'string') {
      conversationId = db.collection('ai_conversations').doc().id;
    }

    // L'historique persisté ne contient que les tours texte user/assistant
    // (pas les allers-retours tool_use/tool_result, qui restent internes à
    // cette invocation) — suffisant pour le contexte conversationnel futur,
    // sans avoir à rejouer la mécanique d'outils entre deux appels.
    const history = await getRecentMessages(db, uid, conversationId);
    const userContent = imageBlock ? [imageBlock, textBlock(message)] : [textBlock(message)];
    const messages = [...history.map(m => ({ role: m.role, content: [textBlock(m.content)] })),
      { role: 'user', content: userContent }];
    const ledger = createToolExecutionLedger();
    // Idempotence persistante inter-invocations (LOT GEMINI 3).
    const persistentLedger = createPersistentToolLedger({ db, admin });

    const userContextText = await buildUserContext(db, uid, safeLocation);
    const system = [textBlock(SYSTEM_PROMPT), ...(userContextText ? [textBlock(userContextText)] : [])];

    const toolsUsed = [];
    // Réponses structurées (Master Prompt 117) — trace de chaque appel
    // d'outil réellement exécuté ce tour (nom + résultat réel), utilisée
    // après coup pour construire `response` de façon déterministe, jamais
    // en reparsant le texte de Claude.
    const toolCalls = [];
    let turnsTaken       = 0;
    let inputTokens       = 0;
    let outputTokens      = 0;
    let providerUsed      = null;
    let modelUsed         = null;

    async function callModel(withTools) {
      try {
        const turn = await aiGateway.generateTurn({
          systemPrompt: system,
          messages,
          tools: withTools ? toolSchemas : [],
          maxTokens: MAX_TOKENS,
          canonicalHistory: true,
          turnIndex: turnsTaken,
        }, { uid, conversationId });
        inputTokens += turn.usage.inputTokens;
        outputTokens += turn.usage.outputTokens;
        providerUsed = turn.provider || providerUsed;
        modelUsed = turn.model || modelUsed;
        return turn;
      } catch (err) {
        console.error('azIaChat gateway error:', err.message);
        throw new HttpsError('internal', "AZ IA rencontre un problème. Réessayez dans un instant.");
      }
    }

    let finalText  = null;
    let hitTurnCap = false;

    try {
      for (let turn = 0; turn < MAX_TOOL_TURNS; turn++) {
        turnsTaken = turn + 1;
        const response = await callModel(true);
        for (const call of response.toolCalls) {
          call.canonicalCallId = ledger.identify(call);
          const block = response.assistantMessage?.find(b => b.type === 'tool_call' && b.id === call.id);
          if (block) block.canonicalCallId = call.canonicalCallId;
        }
        messages.push({ role: 'assistant', content: response.assistantMessage });

        const toolUseBlocks = response.toolCalls;
        if (toolUseBlocks.length === 0) {
          finalText = response.text;
          break;
        }

        const toolResults = [];
        for (const block of toolUseBlocks) {
          // Deux couches complémentaires :
          //   1. `ledger` (mémoire) déduplique à l'intérieur de CETTE invocation ;
          //   2. `persistentLedger` (Firestore) déduplique ENTRE invocations —
          //      retry client, double clic, reconnexion, redémarrage de
          //      fonction, instances concurrentes.
          // Seuls les outils à effet durable passent par la couche persistante :
          // une simple lecture n'a rien à réserver.
          const { result } = await ledger.execute(block,
            () => {
              toolsUsed.push(block.name);
              const tool = toolsByName.get(block.name);
              if (!isPersistentTool(tool)) {
                return executeTool(uid, block.name, block.input, conversationId);
              }
              return persistentLedger.execute(
                { uid, conversationId, name: block.name, input: block.input },
                () => executeTool(uid, block.name, block.input, conversationId),
              ).then((outcome) => outcome.result);
            });
          toolCalls.push({ name: block.name, input: block.input, result });
          toolResults.push(toolResultBlock({
            toolCallId: block.id, canonicalCallId: block.canonicalCallId, name: block.name, content: result,
            isError: !!(result && result.error),
          }));
        }
        messages.push({ role: 'user', content: toolResults });

        if (turn === MAX_TOOL_TURNS - 1) {
          hitTurnCap = true;
        }
      }

      if (finalText === null) {
        // Plafond d'outils atteint sans réponse texte — un dernier appel sans
        // outils force une clôture en langage naturel plutôt qu'une boucle infinie.
        const closing = await callModel(false);
        finalText = closing.text;
      }
      finalText = finalText || "Désolé, je n'ai pas pu générer de réponse.";

      await appendMessage(db, admin, uid, conversationId, 'user', message);
      await appendMessage(db, admin, uid, conversationId, 'assistant', finalText);

      logAiObservability({
        userId: uid, status: 'success', durationMs: Date.now() - startTime,
        toolsUsed, turnCount: turnsTaken, inputTokens, outputTokens, hitTurnCap,
      });
      aiProviderService.recordUsage({
        uid, provider: providerUsed, model: modelUsed,
        inputTokens, outputTokens, responseTimeMs: Date.now() - startTime,
        success: true, conversationId, toolUsed: toolsUsed,
      });

      // Réponse structurée (Master Prompt 117) — `amount` n'est pas toujours
      // réechoé par le handler qui a créé l'action en attente ; relu depuis
      // le document Firestore fraîchement créé (source de vérité), une
      // seule lecture ciblée, uniquement quand une confirmation est
      // effectivement en jeu ce tour.
      let pendingActionAmount = null;
      const lastAwaiting = [...toolCalls].reverse().find(c => c.result && c.result.status === 'awaiting_confirmation');
      if (lastAwaiting?.result?.actionId) {
        try {
          const pendingSnap = await db.collection('ai_pending_actions').doc(lastAwaiting.result.actionId).get();
          if (pendingSnap.exists) pendingActionAmount = pendingSnap.data().amount ?? null;
        } catch (err) {
          console.error('azIaChat: failed to re-read pending action amount:', err.message);
        }
      }
      const response = buildTurnResponse({ finalText, toolCalls, pendingActionAmount });

      // `reply` reste inchangé (compatibilité descendante totale — tout
      // client qui ne connaît pas encore `response` continue de fonctionner
      // à l'identique) ; `response` est un ajout pur.
      return { conversationId, reply: finalText, hitTurnCap, response };
    } catch (err) {
      logAiObservability({
        userId: uid, status: 'error', durationMs: Date.now() - startTime,
        toolsUsed, turnCount: turnsTaken, inputTokens, outputTokens,
        errorCode: err.code || 'internal', errorMessage: err.message || null,
      });
      aiProviderService.recordUsage({
        uid, provider: providerUsed, model: modelUsed,
        inputTokens, outputTokens, responseTimeMs: Date.now() - startTime,
        success: false, errorMessage: err.message || null, conversationId, toolUsed: toolsUsed,
      });
      throw err;
    }
  });

  const aiConfirmAction = buildConfirmAction({
    db, admin, onCall, logAudit, HttpsError, toolsByName,
    secrets: aiConfirmActionSecrets,
  });
  const aiCleanupExpiredPendingActions = buildCleanupScheduler({ db, admin, onSchedule });
  // Rappels (Master Prompt 118) — même famille que le scheduler ci-dessus.
  const aiSendDueReminders = buildReminderScheduler({ db, admin, onSchedule, sendToToken });

  // Contrôle utilisateur sur son historique de conversation (Prompt 33) —
  // ai_conversations n'était jamais géré/effacé nulle part avant ce jour.
  // Master Prompt 122 — quota CPU Cloud Run régional : Groupe B, réduction
  // légère de maxInstances uniquement.
  const clearAiHistory = onCall({ maxInstances: 2 }, async (request) => {
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

  return { azIaChat, aiConfirmAction, aiCleanupExpiredPendingActions, clearAiHistory, aiSendDueReminders };
};
