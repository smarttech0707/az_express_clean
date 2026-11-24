# Restaurant v2 — plan du premier essai (préproduction, lot `t7e-lot-1`)

Mission 7E-38. **Rien de ce document n'a été exécuté.** Source de vérité des requêtes : `scripts/restaurant-v2-pilot/firstRun.js` (testé par `functions/test/restaurantV2FirstRun.test.js`). Projet : `az-express-preprod` uniquement.

## Protocole d'appel
- Callable HTTPS : `POST <URL de la fonction>` avec `{"data": {...}}` et `Authorization: Bearer <jeton d'identification du compte appelant>` ; réponse `{"result": ...}` ou `{"error": {...}}`. URL réelle : `firebase functions:list --project az-express-preprod --json`.
- Jeton obtenu à l'exécution (connexion e-mail/mot de passe du compte fictif) ; **jamais écrit, affiché ni versionné**. Identifiants : `%LOCALAPPDATA%\AZ-Express-T7E\t7e-lot-1\credentials.json` (hors dépôt).
- Panier : 2 × plat A (2 500) + 1 × plat B (1 500) = 6 500. Frais 500 (jour) / 1 000 (nuit). Total 7 000 / 7 500. Commission livreur 100 / 200.

## Séquence
| # | Fonction | Appelant | Paramètres | Effets attendus | Argent |
|---|---|---|---|---|---|
| S0 | `partnerOrderActionCF` | admin | `{action:'setPartnerOrdersConfig', patch:{pilotPartnerIds:['t7e-resto'], pilotClientIds:['t7e-client'], clientAccess:'restricted', creationOpen:true, managementFrozen:false}, expectedVersion:0, reason}` | crée `config/partnerOrdersV2` (version 1), audit | aucun |
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
| S0 | `partnerOrderActionCF` setPartnerOrdersConfig | `t7e-admin` | `config/partnerOrdersV2` (v1), `audit_logs`, `rate_limits` | document absent | `pilotPartnerIds=["t7e-resto"]`, `pilotClientIds=["t7e-client"]`, `clientAccess=restricted`, `creationOpen=true` | lecture du document | `cleanup.js` (ferme puis supprime) |
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

## Mission 7E-40 — S0 et fermeture d'urgence
- **S0** : `partnerOrderActionCF` `{action:'setPartnerOrdersConfig', patch:{pilotPartnerIds:['t7e-resto'], pilotClientIds:['t7e-client'], clientAccess:'restricted', creationOpen:true, managementFrozen:false}, expectedVersion:0, reason:'Ouverture temporaire du pilote Restaurant v2 pour essai fictif T7E.'}`. Le patch REMPLACE la liste (aucune fusion) ; seule une nouvelle action de super-administrateur peut la modifier.
- **Fermeture** : `runStep.js … --step CLOSE --execute --confirm "RUN CLOSE t7e-lot-1 az-express-preprod 306761725053"`. Même fonction auditée, `patch:{creationOpen:false}` seul (la liste n'est jamais vidée pour arrêter), `expectedVersion` lue sur le document réel (la version retournée par S0 est mémorisée et un écart est signalé sans bloquer). Possible à tout moment, même après une erreur. La configuration n'est supprimée que par `cleanup.js`, en fin d'essai.
- **Isolation des comptes (Mission 7E-41)** : corrigée côté serveur par la liste blanche `pilotClientIds` + le mode `clientAccess` (`restricted` par défaut, `open` = ouverture générale explicite, confirmée et auditée). **À déployer en préproduction AVANT S0** : `quotePartnerOrderCF`, `createPartnerOrderFromQuoteCF`, `partnerOrderActionCF`. Sans ce déploiement, S0 ne doit pas être exécutée.

## Mission 7E-42 — correctif déployé, test d'isolation à faire AVEC le pilote ouvert
Déployés en préproduction (révisions 00002) : `quotePartnerOrderCF`, `createPartnerOrderFromQuoteCF`, `partnerOrderActionCF`. Un refus obtenu pilote FERMÉ (`PARTNER_NOT_IN_PILOT`) ne prouve PAS la liste blanche ; l'isolation n'est validée en conditions réelles qu'après le test suivant.

**Test cloud de refus d'un client hors lot (à exécuter juste après S0, avant S1) :**
1. Prérequis (nécessite une autorisation distincte) : un 5ᵉ compte fictif hors liste, `t7e-intrus` (Auth `@example.invalid` + `clients/t7e-intrus` marqué `testLotId`, wallet ≥ 7 000), JAMAIS ajouté à `pilotClientIds`. Aucun compte réel n'est utilisé.
2. `quotePartnerOrderCF` avec le jeton de `t7e-intrus` et le panier habituel → attendu : HTTP 200, `success=false`, `error="CLIENT_NOT_IN_PILOT"` ; aucun `tariff_quotes` créé, aucun mouvement.
3. `createPartnerOrderFromQuoteCF` avec le jeton de `t7e-intrus` et un `quoteId` inexistant → `QUOTE_NOT_FOUND` (ne prouve rien seul) ; avec le devis de `t7e-client` → `QUOTE_NOT_FOUND` (propriétaire).
4. `quotePartnerOrderCF` avec le jeton de `t7e-client` → `success=true` (preuve que la liste ouvre bien à l'autorisé).
5. Contrôle : `orders` = 11 (aucune commande), wallets inchangés ; sinon FERMER (`--step CLOSE`).

## Mission 7E-43 — compte intrus créé (préproduction)
`t7e-intrus` (Auth mot de passe + `clients/t7e-intrus`, wallet 0, `testLotId`) existe, hors `pilotClientIds`. Créé par `scripts/restaurant-v2-pilot/intruder.js` (DRY-RUN par défaut, confirmation `ADD-INTRUDER …`). Manifeste étendu (version 2, `extensions[]`), copie de référence `manifest.base.json`, identifiants dans `credentials.intruder.json` (hors dépôt). Le nettoyage (`cleanup.js`) inventorie l'intrus avec le lot et bloque tout si l'intrus a une commande, un devis, un mouvement de wallet, ou figure dans le pilote. L'intrus a un wallet à 0 : le refus attendu (`CLIENT_NOT_IN_PILOT`) intervient AVANT toute lecture du compte, il prouve donc la liste blanche et non l'insuffisance de solde.


## Mission 7E-45 — réouverture auditée, contrôle du pilote réel, fermeture d'urgence indépendante

Constat du 7E-44 : le pilote est fermé (`config/partnerOrdersV2` version 2, `creationOpen=false`, listes et `restricted` inchangés), mais le fichier d'état du runner marque S0 comme faite. S0 refuse (à raison) une configuration existante : il fallait une réouverture explicite.

**Runner (`runStep.js`)**
- Avant CHAQUE étape S1…S11, la configuration réelle est relue : projet préproduction, `pilotPartnerIds=["t7e-resto"]`, `pilotClientIds=["t7e-client"]`, `clientAccess=restricted`, `managementFrozen=false`, `creationOpen=true`, et version égale à `state.configVersion` (écrite par S0/REOPEN). Toute divergence = arrêt avant tout appel (`PILOT_NOT_READY`, `STATE_INCONSISTENT`, `WRONG_PROJECT`).
- `--step REOPEN --expected-version <n> [--execute --confirm "RUN REOPEN t7e-lot-1 az-express-preprod 306761725053"]` : appel audité `setPartnerOrdersConfig` (mêmes paramètres que S0, `expectedVersion` = version réelle, qui doit égaler `--expected-version`). Refus : configuration absente/ouverte/avec listes différentes/`open`/gelée, version périmée, wallets ≠ 40000/5000/0, nombre de commandes ≠ 11, état local avec devis/commande/échec. Seul le runner réécrit l'état (jamais à la main).
- S1 : le scénario jour (frais 500 → total 7 000, commission 100) ou nuit (frais 1 000 → total 7 500, commission 200) est déduit du devis RÉEL (`lot.amountsFromQuote`), cohérent avec `isNight`, puis recoupé avec le barème officiel (±5 min). Le devis `800fead3-86d9-4534-88f6-be0509b41d11` est refusé s'il revient (`RETIRED_QUOTE`).

**Devis antérieur** : `tariff_quotes/800fead3-…` (client `t7e-client`, restaurant `t7e-resto`) est expiré, jamais réutilisé, jamais supprimé à la main. Le nettoyage final (`cleanup.js`, groupe `quote`) l'inventorie et le supprime avec les autres ressources du lot.

**Fermeture d'urgence indépendante** : `node scripts/restaurant-v2-pilot/emergencyClose.js --project az-express-preprod --project-number 306761725053 --credentials-dir <hors dépôt> --execute --confirm "EMERGENCY-CLOSE t7e-lot-1 az-express-preprod 306761725053"`. N'importe ni le runner ni le fichier d'état ; lit la version réelle, envoie `creationOpen:false` seul, un second essai sur conflit de version, vérifie le résultat, ne supprime jamais la configuration. DRY-RUN par défaut.

**Ordre d'exécution du premier parcours réel** (après autorisation) : `REOPEN --expected-version 2` → S1 … S11 (une étape par appel) → `CLOSE` (ou `emergencyClose.js`) → vérifications → nettoyage final sur demande.


## Mission 7E-47 — nettoyage sans `storage.objects.get`, réconciliation financière, reprise sûre

- **Cause du 403** : `cleanup.js` testait l'objet Storage par `file.exists()`, c'est-à-dire `storage.objects.get`, que le compte CLI n'a pas (il a `list`, `create`, `delete`).
- **Correction** (`storageInventory.js`) : inventaire par listing seul (`versions:true`) ; nom exact dérivé d'une commande du lot, bucket `az-express-preprod.firebasestorage.app`, génération, taille, type vérifiés ; objets voisins ou plusieurs générations = conflit ; suppression d'une génération précise avec `ifGenerationMatch`. L'empreinte de l'inventaire inclut la génération.
- **Réconciliation** (`financialReport.js`) : montants, quatre écritures de wallet, commission, devis utilisé, preuves validées, soldes ; tout écart bloque le nettoyage. Rapport local sans secret : `cleanup.js … --report-dir <hors dépôt>`.
- **Ordre de suppression reprenable** : Storage (vérifié) → listes du pilote vidées → tous les documents Firestore en un lot atomique → comptes Auth. Le pilote doit déjà être fermé (sinon conflit).
- Le bucket n'a ni versioning ni suppression logicielle : une suppression Storage est définitive.

## Mission L0-D — livreurs autorisés du pilote (`pilotDriverIds`) : prérequis de S0 et de REOPEN

**Cette section complète et corrige les lignes S0 / REOPEN ci-dessus**, dont le `patch` ne mentionne pas les livreurs.

### Règle
Depuis la Mission 7E-55 (commit `aa3d1b0`), une commande Restaurant/Boulangerie v2 n'est dispatchée, acceptable ou transférable que pour un livreur présent dans `config/partnerOrdersV2.pilotDriverIds`. **Aucun livreur n'est autorisé implicitement** : liste absente, vide ou mal formée = aucun livreur (refus par défaut, `DRIVER_NOT_IN_PILOT`). Le serveur n'a pas été assoupli.

### Où trouver l'identifiant d'un livreur
L'identifiant est l'**uid Firebase Auth** du livreur, qui est aussi l'ID de son document `livreurs/{uid}` (console Firebase → Authentication → Utilisateurs → colonne « UID utilisateur », ou console Firestore → collection `livreurs`). Pour le lot fictif `t7e-lot-1`, c'est `t7e-driver` (uid fixé par `lot.js` et créé par `prepare.js`). Ne jamais le deviner : le copier depuis la console.

### Comment renseigner `pilotDriverIds`
Avant S0 ou REOPEN, fournir explicitement la liste à l'outillage (identifiants séparés par des virgules, sans espaces superflus) :
```
# PowerShell
$env:AZ_PILOT_DRIVER_IDS = "t7e-driver"
# bash
export AZ_PILOT_DRIVER_IDS=t7e-driver
```
`lot.pilotConfigPlan()` ajoute alors `pilotDriverIds: [...]` au `patch` de S0/REOPEN (liste dédoublonnée et triée, 50 identifiants au plus, caractères `A-Z a-z 0-9 _ -`) et au document attendu. S0 devient :
`{action:'setPartnerOrdersConfig', patch:{pilotPartnerIds:['t7e-resto'], pilotClientIds:['t7e-client'], pilotDriverIds:['t7e-driver'], clientAccess:'restricted', creationOpen:true, managementFrozen:false}, expectedVersion:0, reason:<…>}`.
Plusieurs livreurs : `AZ_PILOT_DRIVER_IDS="uid1,uid2"`. Les scripts n'ajoutent jamais un livreur de leur propre initiative.

### Si la liste est absente, vide ou invalide
- S0 et REOPEN sont **bloqués avant tout appel** avec `PILOT_DRIVER_IDS_REQUIRED` (« Livreurs du pilote non fournis… Aucun livreur n'est autorisé par défaut »). Valeur vide, espaces seuls, identifiant contenant `/` ou des espaces, ou plus de 50 entrées : même blocage.
- La **fermeture d'urgence** (`creationOpen:false` seul) reste possible sans liste.
- Le DRY-RUN `prepare.js` reste lisible et signale `blocked` dans `pilotConfig.plan`.
- Hors outillage : si le pilote est ouvert sans livreur listé, le dispatch ne notifie personne et la commande reste `pending` (aucune perte d'argent ; expiration/remboursement habituels).

### Vérifier que le livreur est autorisé
1. Après S0/REOPEN, relire `config/partnerOrdersV2` : `pilotDriverIds` contient l'uid du livreur et `version` a augmenté.
2. Le livreur est en ligne, disponible, GPS de moins de 3 min (`--refresh-driver-gps` si besoin).
3. À S3, le log de dispatch ne doit pas indiquer `notInPilot` pour ce livreur et la commande passe à `assigned`/`broadcast` avec son uid dans `notifiedDriverIds`.

### Vérifier qu'un livreur non autorisé est refusé
Avec un livreur **fictif** absent de la liste (jamais un vrai compte) : il n'apparaît pas dans `notifiedDriverIds` ; s'il appelle `acceptOrder` sur la commande, la réponse est `permission-denied` / `DRIVER_NOT_IN_PILOT` et la commande reste inchangée. Ces refus sont couverts par `dispatchRetry.emulator.test.js` et `pilotDriverRestriction.test.js`.

### Nettoyage
`cleanup.js` remet `pilotDriverIds` à `[]` à la fermeture du lot ; un livreur étranger au lot présent dans la liste est un conflit qui bloque le nettoyage.
