## API — conventions

Aujourd'hui, chaque Cloud Function retourne une forme différente (ex. `initiateFeexPayPayment` renvoie `{txId, paymentUrl, token, message}`, `ekClientConfirmOrder` renvoie `{success: true}`, `azIaChat` renvoie `{conversationId, reply}`) — il n'y a pas d'enveloppe de réponse unifiée `{success, error, message, data, code}`. **Ne pas retrofit les fonctions existantes** (ça casserait tous les appelants Flutter qui parsent déjà ces formes) : adopter une enveloppe cohérente uniquement pour les **nouvelles** Cloud Functions à partir de maintenant, sans renommer les champs de retour de l'existant. Pas de versionnement d'API (`/v1/`) aujourd'hui ; ne pas en introduire sans besoin concret (les callable functions sont déjà versionnées implicitement par déploiement).

