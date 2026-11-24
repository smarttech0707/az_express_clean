'use strict';

/**
 * Historique canonique AZ IA — indépendant du fournisseur.
 *
 * Jusqu'ici, la boucle d'outils (`azia/index.js`) empilait directement des
 * blocs au format Anthropic (`tool_use` / `tool_result`) dans `messages` :
 * l'historique était donc implicitement « du Claude ». Envoyer cet historique
 * à Gemini produirait une requête invalide, et un repli Claude→Gemini en
 * cours de séquence d'outils serait impossible.
 *
 * Ce module définit un format neutre et les conversions
 *   canonique → fournisseur   et   réponse fournisseur → canonique
 * pour Claude et Gemini. Le cœur d'AZ IA ne manipule plus que le canonique.
 *
 * Message canonique :
 *   { role: 'user' | 'assistant', content: [bloc, ...] }
 *
 * Blocs :
 *   { type: 'text',        text }
 *   { type: 'image',       mediaType, data }                  (base64)
 *   { type: 'tool_call',   id, name, input }                  (assistant)
 *   { type: 'tool_result', toolCallId, name, content, isError } (user)
 *
 * `content` d'un tool_result est la valeur métier telle que renvoyée par
 * l'outil (objet ou chaîne) ; chaque convertisseur la sérialise comme son
 * fournisseur l'exige.
 */

const TEXT = 'text';
const IMAGE = 'image';
const TOOL_CALL = 'tool_call';
const TOOL_RESULT = 'tool_result';

// ── Constructeurs ───────────────────────────────────────────────────────────

function textBlock(text) {
  return { type: TEXT, text: String(text ?? '') };
}

function imageBlock({ data, mediaType = 'image/jpeg' }) {
  return { type: IMAGE, data, mediaType };
}

function toolCallBlock({ id, name, input }) {
  return { type: TOOL_CALL, id, name, input: input || {} };
}

function toolResultBlock({ toolCallId, canonicalCallId, name, content, isError = false }) {
  return { type: TOOL_RESULT, toolCallId, name, content, isError: !!isError,
    ...(canonicalCallId ? { canonicalCallId } : {}) };
}

function userMessage(blocks) {
  return { role: 'user', content: Array.isArray(blocks) ? blocks : [blocks] };
}

function assistantMessage(blocks) {
  return { role: 'assistant', content: Array.isArray(blocks) ? blocks : [blocks] };
}

/**
 * Legacy responses may omit a native ID. Synthesize one for protocol pairing;
 * newer native IDs are preserved. Logical replay identity is separate
 * (canonicalCallId), assigned by the invocation's execution ledger.
 */
function synthesizeToolCallId(provider, turnIndex, position, name) {
  return `${provider}-${turnIndex}-${position}-${name}`;
}

function serializeToolContent(content) {
  // Un `tool_result` vide est refusé par les deux fournisseurs au même titre
  // qu'un bloc texte vide : on ne renvoie jamais la chaîne vide.
  if (typeof content === 'string') return content === '' ? '{}' : content;
  try {
    const json = JSON.stringify(content ?? {});
    return json === undefined || json === '' ? '{}' : json;
  } catch {
    return '{"error":"unserializable_tool_result"}';
  }
}

/**
 * Un bloc texte vide rend TOUTE la requête invalide (Anthropic : « messages:
 * text content blocks must be non-empty » ; Gemini rejette de même une partie
 * vide). Un seul bloc vide glissé dans l'historique fait donc échouer le tour
 * suivant en entier, pas seulement le bloc fautif — d'où un filtrage à chaque
 * conversion plutôt qu'une confiance dans l'appelant.
 */
function hasUsableText(block) {
  return typeof block?.text === 'string' && block.text.length > 0;
}

/**
 * Retire les messages vidés de tout bloc exploitable : un `content: []` est
 * lui aussi refusé, et un message sans contenu n'apporte rien au modèle.
 */
function dropEmptyMessages(messages) {
  return messages.filter((message) => Array.isArray(message.parts)
    ? message.parts.length > 0
    : message.content.length > 0);
}

// ── Claude ──────────────────────────────────────────────────────────────────

function toClaudeMessages(messages) {
  return dropEmptyMessages(messages.map((message) => ({
    role: message.role,
    content: message.content.flatMap((block) => {
      switch (block.type) {
        case TEXT:
          // Jamais de bloc vide : il invaliderait la requête entière.
          return hasUsableText(block) ? [{ type: 'text', text: block.text }] : [];
        case IMAGE:
          return [{
            type: 'image',
            source: { type: 'base64', media_type: block.mediaType, data: block.data },
          }];
        case TOOL_CALL:
          return [{ type: 'tool_use', id: block.id, name: block.name, input: block.input }];
        case TOOL_RESULT:
          return [{
            type: 'tool_result',
            tool_use_id: block.toolCallId,
            content: serializeToolContent(block.content),
            is_error: block.isError,
          }];
        default:
          // Un type inconnu est ÉCARTÉ, jamais transformé en bloc texte vide.
          return [];
      }
    }),
  })));
}

/**
 * Réponse Claude → blocs canoniques.
 *
 * Seuls un vrai texte non vide et un `tool_use` produisent un bloc. Tout autre
 * type (`thinking`, ou un bloc introduit par une future version de l'API) est
 * écarté : le convertir en bloc texte — vide, puisqu'il n'a pas de `.text` —
 * réinjectait ce bloc vide dans l'historique, et la requête du tour SUIVANT
 * était alors rejetée en entier par Anthropic (400 « text content blocks must
 * be non-empty »), cassant toute conversation qui déclenche un outil.
 */
function fromClaudeContent(content) {
  return (content || []).flatMap((block) => {
    if (block.type === 'tool_use') {
      return [toolCallBlock({ id: block.id, name: block.name, input: block.input })];
    }
    if (block.type === 'text' && hasUsableText(block)) return [textBlock(block.text)];
    return [];
  });
}

// ── Gemini ──────────────────────────────────────────────────────────────────

/**
 * Generic Gemini content conversion. GeminiProvider adds native IDs and
 * continuation signatures at its boundary; the shared history stays neutral.
 */
function toGeminiContents(messages) {
  return dropEmptyMessages(messages.map((message) => ({
    role: message.role === 'assistant' ? 'model' : 'user',
    parts: message.content.flatMap((block) => {
      switch (block.type) {
        case TEXT:
          // Même contrainte que Claude : une partie texte vide est refusée.
          return hasUsableText(block) ? [{ text: block.text }] : [];
        case IMAGE:
          return [{ inline_data: { mime_type: block.mediaType, data: block.data } }];
        case TOOL_CALL:
          return [{ functionCall: { name: block.name, args: block.input } }];
        case TOOL_RESULT: {
          // Gemini attend un objet ; une valeur non-objet est encapsulée pour
          // rester exploitable par le modèle sans perdre l'information.
          const value = typeof block.content === 'object' && block.content !== null
            ? block.content
            : { result: block.content };
          // Le drapeau d'erreur est ajouté APRÈS la charge utile et sous une
          // clé distincte : un outil qui renvoie déjà `error: "message"` doit
          // conserver son message, tout en restant signalé comme échec.
          return [{
            functionResponse: {
              name: block.name,
              response: block.isError ? { ...value, isError: true } : value,
            },
          }];
        }
        default:
          // Type inconnu écarté, jamais converti en partie texte vide.
          return [];
      }
    }),
  })));
}

/**
 * Convertit les déclarations d'outils AZ IA (format `input_schema`, hérité
 * d'Anthropic) vers le protocole `functionDeclarations` de Gemini, en
 * préservant nom, description et schéma JSON à l'identique.
 */
function toGeminiToolDeclarations(tools) {
  if (!Array.isArray(tools) || tools.length === 0) return [];
  return [{
    functionDeclarations: tools.map((tool) => ({
      name: tool.name,
      description: tool.description || '',
      parameters: sanitizeJsonSchema(tool.input_schema || tool.parameters || { type: 'object', properties: {} }),
    })),
  }];
}

/**
 * Gemini n'accepte qu'un sous-ensemble de JSON Schema : on retire les clés
 * qu'il rejette (`$schema`, `additionalProperties`) sans jamais toucher à la
 * sémantique métier (types, `required`, `enum`, `description`, imbrication).
 */
function sanitizeJsonSchema(schema) {
  if (Array.isArray(schema)) return schema.map(sanitizeJsonSchema);
  if (!schema || typeof schema !== 'object') return schema;
  const out = {};
  for (const [key, value] of Object.entries(schema)) {
    if (key === '$schema' || key === 'additionalProperties') continue;
    out[key] = (key === 'properties' || key === 'items' || key === 'oneOf' || key === 'anyOf')
      ? sanitizeJsonSchema(value)
      : (typeof value === 'object' && value !== null ? sanitizeJsonSchema(value) : value);
  }
  return out;
}

/**
 * Réponse Gemini → blocs canoniques. Ne suppose jamais qu'une réponse est
 * exploitable : `candidates` absent/vide, `parts` absent ou appel de fonction
 * malformé produisent un résultat explicite plutôt qu'un succès silencieux.
 */
function fromGeminiCandidate(json, { turnIndex = 0 } = {}) {
  const candidate = json?.candidates?.[0];
  if (!candidate) {
    return {
      blocks: [], text: '', toolCalls: [],
      finishReason: json?.promptFeedback?.blockReason ? 'blocked' : 'empty',
      blockReason: json?.promptFeedback?.blockReason || null,
    };
  }
  const parts = candidate.content?.parts;
  if (!Array.isArray(parts) || parts.length === 0) {
    return {
      blocks: [], text: '', toolCalls: [],
      finishReason: candidate.finishReason === 'SAFETY' ? 'blocked' : 'empty',
      blockReason: candidate.finishReason === 'SAFETY' ? 'SAFETY' : null,
    };
  }

  const blocks = [];
  const toolCalls = [];
  let position = 0;
  for (const part of parts) {
    // Internal thought summaries/signatures remain provider-owned, not text
    // responses or cross-provider canonical content.
    if (part?.thought) continue;
    if (part?.functionCall) {
      const name = part.functionCall.name;
      if (typeof name !== 'string' || !name) continue;  // appel malformé ignoré
      const args = part.functionCall.args;
      const input = (args && typeof args === 'object' && !Array.isArray(args)) ? args : {};
      const generatedId = synthesizeToolCallId('gemini', turnIndex, position++, name);
      const id = typeof part.functionCall.id === 'string' && part.functionCall.id
        ? part.functionCall.id : generatedId;
      const block = toolCallBlock({ id, name, input });
      blocks.push(block);
      toolCalls.push({ id, name, input });
    } else if (typeof part?.text === 'string') {
      blocks.push(textBlock(part.text));
    }
  }

  return {
    blocks,
    text: blocks.filter((b) => b.type === TEXT).map((b) => b.text).join('').trim(),
    toolCalls,
    finishReason: candidate.finishReason === 'SAFETY' ? 'blocked' : (candidate.finishReason || 'stop'),
    blockReason: candidate.finishReason === 'SAFETY' ? 'SAFETY' : null,
  };
}

module.exports = {
  TEXT, IMAGE, TOOL_CALL, TOOL_RESULT,
  textBlock, imageBlock, toolCallBlock, toolResultBlock,
  userMessage, assistantMessage,
  synthesizeToolCallId, serializeToolContent, sanitizeJsonSchema,
  toClaudeMessages, fromClaudeContent,
  toGeminiContents, toGeminiToolDeclarations, fromGeminiCandidate,
};
