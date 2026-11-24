'use strict';

// Depuis que acceptOrderCF exige le selfie côté serveur, les parcours de test qui ne portent pas sur le selfie
// joignent une URL conforme (chemin acceptance_selfies/<commande>/<livreur>.jpg). Un test qui veut précisément
// l'absence ou une mauvaise photo passe `acceptanceSelfieUrl` explicitement (même `undefined`).
function selfieUrlFor(orderId, uid) {
  return `https://firebasestorage.googleapis.com/v0/b/demo.appspot.com/o/${encodeURIComponent(
    `acceptance_selfies/${orderId}/${uid}.jpg`)}?alt=media&token=t`;
}

function withSelfie(run) {
  return (request) => {
    const data = request?.data;
    if (!data || typeof data.orderId !== 'string' || 'acceptanceSelfieUrl' in data) return run(request);
    return run({ ...request, data: { ...data, acceptanceSelfieUrl: selfieUrlFor(data.orderId, request.auth?.uid) } });
  };
}

module.exports = { selfieUrlFor, withSelfie };
