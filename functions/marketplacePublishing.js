'use strict';

const { HttpsError } = require('firebase-functions/v2/https');

const PRIVATE_ACTIVE_LIMIT = 3;
const PRIVATE_LIFETIME_MS = 15 * 24 * 60 * 60 * 1000;
const EXPIRY_PAGE_SIZE = 200;
const EXPIRY_MAX_PAGES = 10;

function millis(value) {
  if (!value) return null;
  if (typeof value.toMillis === 'function') return value.toMillis();
  if (value instanceof Date) return value.getTime();
  return null;
}

function isActiveProfessionalSeller(seller, nowMs) {
  return seller?.subscriptionStatus === 'active' &&
    millis(seller.subscriptionExpiresAt) != null &&
    millis(seller.subscriptionExpiresAt) > nowMs;
}

function assertPrivatePublicationAllowed({ isProfessional, activeCount }) {
  if (!isProfessional && activeCount >= PRIVATE_ACTIVE_LIMIT) {
    throw new HttpsError(
      'resource-exhausted',
      'Vous avez déjà 3 annonces actives. Masquez une annonce ou passez en compte vendeur professionnel.',
    );
  }
}

function publicationSystemFields({ seller, isProfessional, now, timestamp }) {
  return {
    status: 'active',
    expiresAt: isProfessional
      ? null
      : timestamp.fromMillis(now.toMillis() + PRIVATE_LIFETIME_MS),
    sellerVerified: seller?.verified === true || seller?.isVerified === true,
    sellerVipStatus: seller?.vipStatus === 'active' ? 'active' : 'none',
    priorityLevel: Number.isSafeInteger(seller?.priorityLevel) ? seller.priorityLevel : 0,
  };
}

function validateProduct(product) {
  if (!product || typeof product !== 'object' || Array.isArray(product)) {
    throw new HttpsError('invalid-argument', 'Annonce invalide.');
  }
  if (typeof product.title !== 'string' || !product.title.trim()) {
    throw new HttpsError('invalid-argument', 'Titre requis.');
  }
  if (!Number.isSafeInteger(product.price) || product.price <= 0) {
    throw new HttpsError('invalid-argument', 'Prix invalide.');
  }
}

function buildPublishMarketplaceProduct({ db, admin }) {
  return async (request) => {
    if (!request.auth || request.auth.token.firebase?.sign_in_provider === 'anonymous') {
      throw new HttpsError('unauthenticated', 'Compte authentifié requis.');
    }
    const uid = request.auth.uid;
    const product = request.data?.product;
    validateProduct(product);
    const productRef = db.collection('marketplace_products').doc();
    const sellerRef = db.collection('sellers').doc(uid);
    const now = admin.firestore.Timestamp.now();
    console.log(`[marketplace-publish] start uid=${uid} productId=${productRef.id}`);

    console.log(`[marketplace-publish] transaction-start uid=${uid} productId=${productRef.id}`);
    await db.runTransaction(async (tx) => {
      const sellerSnap = await tx.get(sellerRef);
      const seller = sellerSnap.exists ? sellerSnap.data() : null;
      console.log(`[marketplace-publish] seller-loaded uid=${uid} productId=${productRef.id}`);
      const professional = isActiveProfessionalSeller(seller, now.toMillis());
      if (!professional) {
        const activeQuery = db.collection('marketplace_products')
          .where('sellerId', '==', uid)
          .where('status', '==', 'active')
          .limit(PRIVATE_ACTIVE_LIMIT + 1);
        const activeSnap = await tx.get(activeQuery);
        assertPrivatePublicationAllowed({ isProfessional: false, activeCount: activeSnap.size });
        console.log(`[marketplace-publish] active-count-complete uid=${uid} productId=${productRef.id}`);
      }
      tx.set(productRef, {
        ...product,
        sellerId: uid,
        ...publicationSystemFields({ seller, isProfessional: professional, now, timestamp: admin.firestore.Timestamp }),
        createdAt: now,
      });
      console.log(`[marketplace-publish] product-write-prepared uid=${uid} productId=${productRef.id}`);
    });
    console.log(`[marketplace-publish] transaction-complete uid=${uid} productId=${productRef.id}`);
    console.log(`[marketplace-publish] response-sent uid=${uid} productId=${productRef.id}`);
    return { productId: productRef.id };
  };
}

function buildRepublishMarketplaceProduct({ db, admin }) {
  return async (request) => {
    if (!request.auth || request.auth.token.firebase?.sign_in_provider === 'anonymous') {
      throw new HttpsError('unauthenticated', 'Compte authentifié requis.');
    }
    const uid = request.auth.uid;
    const productId = String(request.data?.productId || '').trim();
    if (!productId) throw new HttpsError('invalid-argument', 'Annonce requise.');
    const productRef = db.collection('marketplace_products').doc(productId);
    const sellerRef = db.collection('sellers').doc(uid);
    const now = admin.firestore.Timestamp.now();

    await db.runTransaction(async (tx) => {
      const [productSnap, sellerSnap] = await Promise.all([tx.get(productRef), tx.get(sellerRef)]);
      if (!productSnap.exists) throw new HttpsError('not-found', 'Annonce introuvable.');
      const product = productSnap.data();
      if (product.sellerId !== uid) throw new HttpsError('permission-denied', 'Annonce non autorisée.');
      if (!['hidden', 'sold'].includes(product.status)) {
        throw new HttpsError('failed-precondition', 'Seule une annonce inactive peut être republiée.');
      }
      const seller = sellerSnap.exists ? sellerSnap.data() : null;
      const professional = isActiveProfessionalSeller(seller, now.toMillis());
      if (!professional) {
        const activeQuery = db.collection('marketplace_products')
          .where('sellerId', '==', uid)
          .where('status', '==', 'active')
          .limit(PRIVATE_ACTIVE_LIMIT + 1);
        const activeSnap = await tx.get(activeQuery);
        assertPrivatePublicationAllowed({ isProfessional: false, activeCount: activeSnap.size });
      }
      tx.update(productRef, publicationSystemFields({
        seller,
        isProfessional: professional,
        now,
        timestamp: admin.firestore.Timestamp,
      }));
    });
    return { productId };
  };
}

function shouldExpireProduct(product, nowMs) {
  const expiry = millis(product?.expiresAt);
  return product?.status === 'active' && expiry != null && expiry <= nowMs;
}

function buildExpireMarketplaceProducts({ db, admin }) {
  return async () => {
    const now = admin.firestore.Timestamp.now();
    let expired = 0;
    let pages = 0;
    while (pages < EXPIRY_MAX_PAGES) {
      const query = db.collection('marketplace_products')
        .where('status', '==', 'active')
        .where('expiresAt', '<=', now)
        .orderBy('expiresAt')
        .limit(EXPIRY_PAGE_SIZE);
      const snap = await query.get();
      if (snap.empty) break;
      const batch = db.batch();
      for (const doc of snap.docs) {
        batch.update(doc.ref, { status: 'hidden', updatedAt: admin.firestore.FieldValue.serverTimestamp() });
      }
      await batch.commit();
      expired += snap.size;
      pages += 1;
      if (snap.size < EXPIRY_PAGE_SIZE) break;
    }
    if (pages === EXPIRY_MAX_PAGES) {
      console.warn(`[marketplace-expiry] plafond atteint pages=${pages} expirées=${expired}`);
    }
    console.log(`[marketplace-expiry] pages=${pages} expirées=${expired}`);
    return { pages, expired };
  };
}

module.exports = {
  PRIVATE_ACTIVE_LIMIT,
  PRIVATE_LIFETIME_MS,
  EXPIRY_PAGE_SIZE,
  EXPIRY_MAX_PAGES,
  isActiveProfessionalSeller,
  assertPrivatePublicationAllowed,
  publicationSystemFields,
  shouldExpireProduct,
  buildPublishMarketplaceProduct,
  buildRepublishMarketplaceProduct,
  buildExpireMarketplaceProducts,
};
