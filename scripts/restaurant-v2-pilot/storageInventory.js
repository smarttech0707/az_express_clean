'use strict';

// Inventaire et suppression d'objets Storage du lot SANS storage.objects.get (Mission 7E-47).
// Le compte CLI dispose de list/create/delete mais pas de get : `file.exists()` / `getMetadata()` échouent en HTTP 403. Le listing
// (storage.objects.list) retourne pourtant toutes les métadonnées utiles : bucket, nom exact, génération, taille, type, empreintes.
// Règles : bucket unique du lot, noms EXACTS dérivés d'une commande du lot (jamais de suppression par préfixe), une seule génération
// courante, aucun objet voisin partageant le nom comme préfixe, suppression avec précondition de génération.

const lot = require('./lot');
const guard = require('./guard');

const ORDER_ID = /^[A-Za-z0-9_-]{1,128}$/;
const DRIVER = lot.IDENTITIES.driver.uid;
const MAX_BYTES = 5 * 1024 * 1024;
const GENERATION = /^[0-9]{1,30}$/;

// Seuls noms qu'un parcours du lot peut produire (selfie d'acceptation exigé par acceptOrderCF, photo de livraison).
const candidateNames = (orderId) => {
  if (!ORDER_ID.test(String(orderId))) throw new guard.GuardError('BAD_ORDER_ID', 'Identifiant de commande invalide');
  return [`acceptance_selfies/${orderId}/${DRIVER}.jpg`, `delivery_photos/${DRIVER}/${orderId}.jpg`];
};
const pathAllowed = (name) => /^(acceptance_selfies\/[A-Za-z0-9_-]{1,128}\/t7e-driver\.jpg|delivery_photos\/t7e-driver\/[A-Za-z0-9_-]{1,128}\.jpg)$/.test(name);
const orderIdOf = (name) => (/^acceptance_selfies\/([^/]+)\//.exec(name) || /^delivery_photos\/[^/]+\/([^/]+)\.jpg$/.exec(name) || [])[1];

function assertBucket(bucket) {
  if (!bucket || bucket.name !== lot.TARGET.storageBucket) throw new guard.GuardError('WRONG_BUCKET', `Bucket inattendu : ${bucket && bucket.name}`);
}

// Retourne { item } (objet trouvé et vérifié), { absent: true } ou { conflicts: [...] }. Lecture seule : un seul appel de listing.
async function inventoryObject({ bucket, name, orderIds }) {
  assertBucket(bucket);
  if (!pathAllowed(name)) throw new guard.GuardError('PATH_NOT_ALLOWED', `Objet Storage hors liste blanche : ${name}`);
  if (!orderIds.includes(orderIdOf(name))) throw new guard.GuardError('PATH_NOT_ALLOWED', `Objet sans commande du lot : ${name}`);
  const [files] = await bucket.getFiles({ prefix: name, versions: true, autoPaginate: false, maxResults: 20 });
  const exact = files.filter((f) => f.name === name);
  const neighbours = files.filter((f) => f.name !== name);
  const conflicts = [];
  if (neighbours.length) conflicts.push({ type: 'storage', id: name, reason: `objets voisins partageant le préfixe : ${neighbours.map((f) => f.name).join(', ')}` });
  if (exact.length === 0) return conflicts.length ? { conflicts } : { absent: true };
  if (exact.length > 1) return { conflicts: [...conflicts, { type: 'storage', id: name, reason: `plusieurs générations (${exact.length}) : correspondance ambiguë` }] };
  const m = exact[0].metadata || {};
  if (m.bucket !== lot.TARGET.storageBucket) conflicts.push({ type: 'storage', id: name, reason: 'bucket du métadonnée différent' });
  if (m.name !== name) conflicts.push({ type: 'storage', id: name, reason: 'nom du métadonnée différent' });
  if (!GENERATION.test(String(m.generation))) conflicts.push({ type: 'storage', id: name, reason: 'génération illisible' });
  if (m.timeDeleted) conflicts.push({ type: 'storage', id: name, reason: 'version supprimée (non courante)' });
  const size = Number(m.size);
  if (!(size > 0 && size < MAX_BYTES)) conflicts.push({ type: 'storage', id: name, reason: `taille inattendue (${m.size})` });
  if (m.contentType !== 'image/jpeg') conflicts.push({ type: 'storage', id: name, reason: `type inattendu (${m.contentType})` });
  if (conflicts.length) return { conflicts };
  return { item: { type: 'storage', path: name, bucket: m.bucket, generation: String(m.generation), size, md5Hash: m.md5Hash || null, group: 'storage' } };
}

// Inventaire complet des objets Storage des commandes du lot.
async function inventoryOrders({ bucket, orderIds }) {
  const items = []; const conflicts = [];
  for (const orderId of orderIds) {
    for (const name of candidateNames(orderId)) {
      const r = await inventoryObject({ bucket, name, orderIds });
      if (r.item) items.push(r.item);
      if (r.conflicts) conflicts.push(...r.conflicts);
    }
  }
  return { items, conflicts };
}

// Suppression : relecture immédiate (génération inchangée), puis suppression de CETTE génération avec précondition.
async function deleteObject({ bucket, item, orderIds }) {
  assertBucket(bucket);
  if (item.bucket !== lot.TARGET.storageBucket) throw new guard.GuardError('WRONG_BUCKET', 'Bucket de l’élément inattendu');
  const now = await inventoryObject({ bucket, name: item.path, orderIds });
  if (now.absent) return { deleted: false, alreadyAbsent: true };
  if (now.conflicts) throw new guard.GuardError('CONFLICTS', `Objet Storage en conflit : ${now.conflicts.map((c) => c.reason).join('; ')}`);
  if (now.item.generation !== item.generation) throw new guard.GuardError('OBJECT_REPLACED', `Objet remplacé depuis l’inventaire : ${item.path}`);
  try {
    await bucket.file(item.path, { generation: item.generation }).delete({ ifGenerationMatch: item.generation });
  } catch (err) {
    if (err && err.code === 412) throw new guard.GuardError('OBJECT_REPLACED', `Précondition de génération refusée : ${item.path}`);
    if (err && err.code === 404) return { deleted: false, alreadyAbsent: true };
    throw err;
  }
  return { deleted: true };
}

module.exports = { candidateNames, pathAllowed, orderIdOf, inventoryObject, inventoryOrders, deleteObject, assertBucket };
