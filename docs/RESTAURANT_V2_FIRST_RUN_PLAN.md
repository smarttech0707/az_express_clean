# Restaurant v2 — plan du premier essai (préproduction, lot `t7e-lot-1`)

Mission 7E-38. **Rien de ce document n'a été exécuté.** Source de vérité des requêtes : `scripts/restaurant-v2-pilot/firstRun.js` (testé par `functions/test/restaurantV2FirstRun.test.js`). Projet : `az-express-preprod` uniquement.

## Protocole d'appel
- Callable HTTPS : `POST <URL de la fonction>` avec `{"data": {...}}` et `Authorization: Bearer <jeton d'identification du compte appelant>` ; réponse `{"result": ...}` ou `{"error": {...}}`. URL réelle : `firebase functions:list --project az-express-preprod --json`.
- Jeton obtenu à l'exécution (connexion e-mail/mot de passe du compte fictif) ; **jamais écrit, affiché ni versionné**. Identifiants : `%LOCALAPPDATA%\AZ-Express-T7E\t7e-lot-1\credentials.json` (hors dépôt).
- Panier : 2 × plat A (2 500) + 1 × plat B (1 500) = 6 500. Frais 500 (jour) / 1 000 (nuit). Total 7 000 / 7 500. Commission livreur 100 / 200.

## Séquence
| # | Fonction | Appelant | Paramètres | Effets attendus | Argent |
|---|---|---|---|---|---|
| S0 | `partnerOrderActionCF` | admin | `{action:'setPartnerOrdersConfig', patch:{pilotPartnerIds:['t7e-resto'], creationOpen:true}, expectedVersion:0, reason}` | crée `config/partnerOrdersV2` (version 1), audit | aucun |
| S1 | `quotePartnerOrderCF` | client | `{sellerType:'restaurant', sellerId:'t7e-resto', items:[{itemId,qty}], destination:{lat,lng}}` | `tariff_quotes/<quoteId>` ouvert | aucun |
| S2 | `createPartnerOrderFromQuoteCF` | client | choix identiques + `quoteId`, `paymentMethod:'wallet'`, `confirmedAmount`, `deliveryAddress` | `orders/<id>` pending, devis `used`, journal `order_<id>` | client −total |
| S2b | script `prepare.js --refresh-driver-gps` | — | confirmation `REFRESH t7e-lot-1 az-express-preprod 306761725053` | GPS livreur frais (< 3 min exigé au dispatch) | aucun |
| S3 | `partnerOrderActionCF` | restaurant | `{orderId, action:'acceptPartnerOrder'}` | dispatch serveur, un livreur → `assigned` | aucun |
| S4 | idem | restaurant | `action:'startPreparation'` | `sellerStatus: preparing` | aucun |
| S5 | idem | restaurant | `action:'markReady'` | `sellerStatus: ready` | aucun |
| S6 | Storage (REST) | livreur | POST `acceptance_selfies/<orderId>/t7e-driver.jpg`, `image/jpeg`, ≈ 2 Ko | 1 objet Storage | aucun |
| S7 | `acceptOrderCF` | livreur | `{orderId, acceptanceSelfieUrl}` | `accepted`, commission journalisée | livreur −commission |
| S8 | `prepareOrderProof` | restaurant | `{orderId, type:'pickup'}` | session + version de preuve (hachages) | aucun |
| S9 | `confirmOrderPickupWithProof` | livreur | `{orderId, pin}` (ou `token`) | `picked_up` | aucun |
| S10 | `prepareOrderProof` | client | `{orderId, type:'delivery'}` | preuve de livraison | aucun |
| S11 | `confirmOrderDeliveryWithProof` | livreur | `{orderId, proofToken}` (ou `proofPin`) | `delivered`, une écriture `commissions` | restaurant +6 500, livreur +frais |

`dispatchOrderToDriver` : **non appelée**. Pour une commande v2 et un appelant non administrateur elle renvoie `server_managed` sans effet ; le dispatch est déclenché par S3.

## Soldes attendus (jour)
Client 40 000 → 33 000 · Livreur 5 000 → 4 900 (S7) → 5 400 (S11) · Restaurant 0 → 6 500. Nuit : total 7 500, commission 200.

## Critères généraux
- **PASS** : `success=true` à chaque étape, soldes exacts au FCFA, un seul document `orders`, une seule écriture `commissions`, rejeu sans second mouvement.
- **FAIL / arrêt immédiat** : écart de solde, double débit ou crédit, statut inattendu, erreur de permission, notification réellement envoyée.
- QR et PIN des réponses S8/S10 sont sensibles : ne pas les journaliser.

## Selfie synthétique (S6)
`scripts/restaurant-v2-pilot/selfie.js` + `selfie.b64.txt` : JPEG 96×96 (dégradé géométrique, sans personne ni EXIF), 1 976 octets, < 5 Mo. Chemin exact `acceptance_selfies/<orderId>/t7e-driver.jpg` (règle Storage : nom = uid du livreur). L'URL de téléchargement doit être de la forme `https://firebasestorage.googleapis.com/v0/b/az-express-preprod.<bucket>/o/<chemin encodé>?alt=media&token=<jeton>` (vérifiée par `proofStorage.storageObjectOfUrl`). L'objet est supprimé au nettoyage (`cleanup.js`).

## GPS du livreur
Le GPS fictif est périmé (> 3 min) : à rafraîchir **juste avant S3** avec la commande S2b. Seuls `lat`, `lng`, `isOnline`, `updatedAt` de `livreurs/t7e-driver` sont modifiés.

## Prérequis à l'exécution (non faits en 7E-38)
Ouverture du pilote (S0), écritures Firestore et Storage, appels de fonctions : chacun exige une autorisation explicite. Notifications : `NOTIFICATIONS_SEND=off` doit rester actif. Fermeture et nettoyage : `cleanup.js` (voir README du dossier).

---

# Mission 7E-39 — exécution par étapes (tableau d'exécution)

Outil : `scripts/restaurant-v2-pilot/runStep.js`. **Une seule étape par appel**, DRY-RUN par défaut (aucune connexion). Exécution réelle :

```
node scripts/restaurant-v2-pilot/runStep.js --project az-express-preprod --project-number 306761725053 \
  --state-dir <dossier hors dépôt> --credentials-dir "%LOCALAPPDATA%\AZ-Express-T7E\t7e-lot-1" --step S3 \
  --execute --confirm "RUN S3 t7e-lot-1 az-express-preprod 306761725053"
```
Variable d'environnement : `T7E_API_KEY` (clé web de l'application Android de préproduction, jamais écrite). Garde-fous : projet + numéro vérifiés (hors ligne puis en ligne), production refusée, confirmation exacte par étape, ordre S0→S11 imposé, aucune reprise automatique, la première erreur fige le parcours (`failed` dans le fichier d'état : revue humaine), identité des jetons vérifiée (projet + uid `t7e-`), lectures limitées au lot (aucune commande historique), données envoyées limitées au lot. L'état (hors dépôt, 0600) contient le PIN/jeton de preuve (valables 15 min) : à supprimer après l'essai. Rien n'est affiché : ni jeton, ni QR, ni PIN.

| Étape | Fonction | Identité | Écriture cloud attendue | Précondition (contrôlée) | Résultat attendu | Vérification après écriture | Arrêt |
|---|---|---|---|---|---|---|---|
| S0 | `partnerOrderActionCF` setPartnerOrdersConfig | `t7e-admin` | `config/partnerOrdersV2` (v1), `audit_logs`, `rate_limits` | document absent | `pilotPartnerIds=["t7e-resto"]`, `creationOpen=true` | lecture du document | `cleanup.js` (ferme puis supprime) |
| S1 | `quotePartnerOrderCF` | `t7e-client` | `tariff_quotes/<id>` (open), `rate_limits` | pilote ouvert au seul restaurant fictif | total = barème officiel à l'heure de l'appel (7 000 de jour ; 7 500 de nuit → **arrêt** si écart) | total, `isNight` | devis expire seul |
| S2 | `createPartnerOrderFromQuoteCF` | `t7e-client` | `orders/<id>` pending, journal wallet client, devis `used` | devis ouvert | client 40 000 → 33 000 | soldes + 1 seul document `orders` | annulation/refus → remboursement intégral |
| S2b | `prepare.js --refresh-driver-gps` | script (ADC) | `livreurs/t7e-driver` : lat, lng, isOnline, updatedAt | commande pending | GPS < 60 s | âge du GPS | — |
| S3 | `partnerOrderActionCF` acceptPartnerOrder | `t7e-resto` | `orders/<id>`, `livreurs/t7e-driver.pendingOrderId` | GPS < 60 s (sinon `GPS_STALE`) | `assigned`, `dispatched=true` | statut | `refusePartnerOrder` (avant préparation) |
| S4 | idem startPreparation | `t7e-resto` | `orders/<id>.sellerStatus` | `assigned` | `preparing` | statut | refus impossible ensuite |
| S5 | idem markReady | `t7e-resto` | `orders/<id>.sellerStatus` | `preparing` | `ready` | statut | — |
| S6 | Storage REST | `t7e-driver` | 1 objet `acceptance_selfies/<id>/t7e-driver.jpg` (1 976 o) | `ready` | HTTP 200 + jeton | URL reconnue | supprimé par `cleanup.js` |
| S7 | `acceptOrderCF` | `t7e-driver` | `orders/<id>`, wallet livreur, journal commission | selfie déposé | `accepted`, livreur 5 000 → 4 900 | soldes | refus restaurant → commission rendue |
| S8 | `prepareOrderProof` pickup | `t7e-resto` | `delivery_proofs` (+ versions) | `accepted` + `ready` | PIN 6 chiffres | présence en état | expire 15 min |
| S9 | `confirmOrderPickupWithProof` | `t7e-driver` | `orders/<id>` picked_up | preuve valide | `picked_up` | statut | 5 PIN faux = verrou |
| S10 | `prepareOrderProof` delivery | `t7e-client` | session + version de preuve | `picked_up` | PIN + jeton | présence en état | expire 15 min |
| S11 | `confirmOrderDeliveryWithProof` | `t7e-driver` | `orders/<id>` delivered, wallets restaurant et livreur, `commissions` | preuve valide | restaurant 6 500 ; livreur 5 400 | soldes exacts, 1 commission | irréversible |
| Fin | fermeture + nettoyage | admin / script | `config/partnerOrdersV2` fermé puis supprimé, lot supprimé | — | pilote fermé | inventaire vide | `cleanup.js` (DRY-RUN puis confirmation) |

Écritures cloud faites hors des fonctions déployées : (1) ouverture du pilote, (2) rafraîchissement du GPS du livreur, (3) un objet Storage, (4) l'état local hors dépôt. Le reste est écrit par les fonctions déployées.
