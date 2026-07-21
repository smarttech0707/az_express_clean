'use strict';

const { trackOrder, createDeliveryOrder, createShoppingOrder, cancelOrder } = require('./tools/delivery');
const { getWalletBalance, getWalletTransactions, initiateWalletRecharge } = require('./tools/wallet');
const { searchMarketplace, createMarketplaceOrder } = require('./tools/marketplace');
const { searchRestaurants, createRestaurantOrder } = require('./tools/restaurants');
const { searchPharmacies, createPharmacieOrder }   = require('./tools/pharmacies');
const { searchRealEstate, requestPropertyVisit } = require('./tools/immobilier');
const { createSupportTicket } = require('./tools/support');
const { trackEkbineOrder, createEkbineOrder } = require('./tools/ekbine');
const { rememberUserInfo, rememberNamedAddress } = require('./tools/memory');
const { createReminder } = require('./tools/reminders');

// Construit la liste des outils disponibles pour AZ IA. Chaque outil expose
// {name, description, input_schema, handler(uid, input, ctx)} — le handler
// est la seule porte d'entrée vers Firestore/Storage pour AZ IA. Un outil
// sensible expose en plus {confirmHandler, afterConfirm} pour le mécanisme
// de confirmation server-side (voir pendingActions.js).
function buildRegistry({ db, admin, logAudit, checkRateLimit, HttpsError, axios, feexpayOperatorCode, FEEXPAY_TOKEN, FEEXPAY_API_URL, WEBHOOK_URL }) {
  return [
    trackOrder({ db }),
    createDeliveryOrder({ db, admin, HttpsError }),
    createShoppingOrder({ db, admin, HttpsError }),
    cancelOrder({ db, admin, HttpsError }),
    getWalletBalance({ db }),
    getWalletTransactions({ db }),
    initiateWalletRecharge({ db, admin, checkRateLimit, axios, feexpayOperatorCode, FEEXPAY_TOKEN, FEEXPAY_API_URL, WEBHOOK_URL }),
    searchMarketplace({ db }),
    createMarketplaceOrder({ db, admin, HttpsError }),
    searchRestaurants({ db }),
    createRestaurantOrder({ db, admin, HttpsError }),
    searchPharmacies({ db }),
    createPharmacieOrder({ db, admin, HttpsError }),
    searchRealEstate({ db }),
    requestPropertyVisit({ db, admin, HttpsError }),
    createSupportTicket({ db, admin, logAudit }),
    trackEkbineOrder({ db }),
    createEkbineOrder({ db, admin, HttpsError }),
    rememberUserInfo({ db, admin }),
    rememberNamedAddress({ db, admin }),
    createReminder({ db, admin }),
  ];
}

module.exports = { buildRegistry };
