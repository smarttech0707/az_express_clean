# Phase 3 — réception par SMS, simulation seulement

## État et périmètre

Implémentation locale sur `sync-windows-20260825`, sans activation, déploiement,
SMS réel, commit, push, modification de version ou de règlement financier.
Les phases 1 et 2 et les modifications locales antérieures sont conservées.
Ce document complète, sans remplacer, `DELIVERY_PROOFS_PHASE2.md`.

Fichiers nouveaux :

- `functions/smsProvider.js`
- `functions/deliveryProofSms.js`
- `functions/test/deliveryProofSms.test.js`
- `functions/test/smsTestHelpers.js`
- `lib/delivery_proofs/delivery_sms_panel.dart`
- `test/delivery_proofs/delivery_sms_panel_test.dart`
- `docs/DELIVERY_PROOFS_PHASE3_SMS.md`

Fichiers étendus :

- `functions/index.js` : quatre callables et un déclencheur Firestore.
- `functions/deliveryProofs.js` : conservation des métadonnées de session lors
  d'une génération QR (notamment compteurs d'accès destinataire phase 2).
- `firestore.rules` : livreur et partenaire ne peuvent plus modifier
  `recipientPhone` ou `recipientName`. Les champs restent présents ; aucun
  changement des champs expéditeur, des statuts historiques ou du GPS.
- `rules-tests/firestore.rules.test.js` : deux tests supplémentaires.
- `lib/delivery_proofs/proof_presentation.dart` : panneau SMS dans la réception,
  conservation du partage WhatsApp sécurisé existant.
- `lib/screens/driver/driver_dashboard.dart` : signalement d'arrivée, sans PIN.

## Parcours et déclenchement

Pour soi : présentation QR/PIN phase 2 inchangée, aucun SMS implicite.
Pour un proche : après récupération validée (`picked_up`, `qr_v1`), le client
choisit le SMS dans « Code de réception ». Aucun numéro libre n'est demandé.
Le serveur lit `recipientName` et `recipientPhone` de la commande et fige la
destination, le propriétaire, le livreur et la version d'affectation dans un
document privé. Une modification ultérieure bloque l'envoi.

Le livreur assigné signale son arrivée, après confirmation dans l'interface.
Cela fait passer le document privé de `waiting_arrival` à `queued` ; le
déclencheur serveur émet automatiquement la preuve et appelle l'adaptateur.
Le choix SMS doit précéder ce signalement ; sinon le livreur doit réessayer
après le choix du client. L'arrivée est déclarée par le livreur, pas certifiée
par géorepérage. Le suivi GPS existant est conservé.

Le destinataire n'a besoin ni d'application, ni de connexion, ni de WhatsApp.
Le PIN SMS est le PIN de la preuve de réception existante : aucune seconde
méthode de validation, aucun changement de la fonction de règlement.
Le livreur saisit le PIN fourni après remise du colis dans le scanner phase 2.

## Contrats et stockage

Tous les callables n'acceptent que `{orderId}` ; un champ `phone`, `pin` ou
`body` supplémentaire est rejeté.

- `configureDeliverySms` : client propriétaire, jamais livreur assigné.
- `markDeliverySmsArrival` : livreur assigné, une seule mise en file initiale.
  Retourne uniquement un succès, aucun numéro/code/état fournisseur.
- `getDeliverySmsStatus` : propriétaire seulement, projection sans secrets.
- `retryDeliverySms` : propriétaire seulement, contraintes serveur cumulées.
- `dispatchDeliverySms` : déclencheur de mise à jour des documents privés,
  relit toujours l'état actuel pour ignorer les événements rejoués.

`delivery_proofs/sms_<orderId base64url>` contient destination et état privé.
La sous-collection `attempts` contient seulement dates, expiration et état.
`delivery_proofs/sms_budget_<jour>_<clé>` conserve les compteurs ; le numéro
utilisé dans les clés de budget est un HMAC, jamais un numéro en clair.
Les règles existantes refusent toute lecture/écriture de cette collection aux
clients, y compris au propriétaire. Aucun état SMS n'est écrit dans `orders`.

Les preuves restent dans les sessions/versions phase 1. Seuls les hachages du
PIN et du token y sont stockés ; le SMS complet et le PIN ne sont jamais
persistés. Ils existent uniquement en mémoire pendant l'appel à l'adaptateur.
Ni erreur brute fournisseur, ni corps SMS, ni PIN, ni clé ne sont journalisés.

## Doublons, expiration, reprise et coûts

Une transaction réserve simultanément la preuve, l'essai et les budgets avant
le premier appel fournisseur. L'envoi est hors transaction, donc aucun effet
externe lors des répétitions automatiques de transactions Firestore.
Une mise à jour répétée ne renvoie pas le SMS. L'adaptateur reçoit un
`idempotencyKey` unique par preuve ; un adaptateur réel devra respecter le
contrat de son fournisseur sans supposer son support de l'idempotence.

Validité : 15 minutes à partir de la réservation, cinq erreurs PIN maximum,
trois générations par étape partagées avec QR et accès invité. Un renvoi crée
une nouvelle preuve et révoque la précédente. Aucun renvoi pendant les quinze
minutes du code précédent, même après un refus fournisseur, pour borner les
coûts et les situations ambiguës. Une indisponibilité détectée avant émission
permet une nouvelle demande après 60 secondes, sans consommer de preuve.

Plafonds conservateurs, atomiques, par jour UTC : 100 essais globalement,
10 par client et 5 par numéro ; maximum 3 par commande. Les réservations sont
comptées même après échec. Ce sont des plafonds d'essais/segments, pas un
budget monétaire garanti indépendamment du futur contrat fournisseur.
Les plafonds atteints bloquent l'envoi : assistance/voie de secours, sans
augmentation automatique. Une réaffectation ou un changement de destination
demande également une résolution contrôlée ; aucun déverrouillage client.

Si l'appel expire ou si le processus s'arrête entre réservation et résultat,
le SMS peut avoir été envoyé ou non. L'état devient `unknown` (après 60 secondes
pour un `sending` abandonné) ; aucun renvoi aveugle automatique. Le propriétaire
peut demander une nouvelle preuve après expiration, dans les limites.
Un crash avant la réservation est repris par les événements Firebase ; après
la réservation, priorité à l'absence de doublon, au prix d'une reprise manuelle.
Cette architecture ne prétend pas garantir une livraison SMS exactement une fois.

Le message est en caractères GSM-7 simples et inférieur à 160 caractères :
un seul segment pour le modèle actuel. « Accepté » n'est jamais présenté comme
« reçu ». La simulation est explicitement indiquée. Aucun webhook DLR réel
n'est installé avant choix et validation du fournisseur.

Secours : le client peut générer un nouveau QR/PIN dans sa présentation et
transmettre ce PIN au destinataire par appel au numéro préalablement vérifié,
jamais au livreur. Le nouveau code remplace l'ancien SMS. Le partage WhatsApp
phase 2 demeure facultatif, avec code de récupération séparé du lien. Si les
limites sont épuisées ou l'identité incertaine, contacter l'assistance, sans
contourner la preuve ni modifier directement le statut de livraison.

## Fournisseurs étudiés — sources officielles consultées le 14 octobre 2026

| Critère | Orange SMS CI 2.0 | Twilio | Infobip |
|---|---|---|---|
| Orange / MTN / Moov CI | Annonce « any operator » en CI ; essais des trois réseaux encore nécessaires | Page pays CI disponible ; les trois routes ne sont pas individuellement certifiées par les sources consultées | Couverture mondiale annoncée (CI non exclue de la liste publiée), routes des trois réseaux à confirmer |
| API | REST documentée, identifiant/secret d'application | REST Messages API documentée | API SMS documentée |
| Prix public vérifié | 100 SMS : 725 FCFA ; 1 000 : 7 260 FCFA ; 10 000 : 72 600 FCFA | Tarif CI chiffré non récupéré de manière fiable ; demander prix par segment et réseau | Tarif CI non établi dans les sources consultées ; devis requis |
| Frais d'activation | Aucun frais séparé identifié ; confirmation commerciale requise | Non établis, vérifier enregistrement expéditeur et surcharges | Non établis, devis requis |
| Compte | Compte développeur/application, SIM Orange et achat de forfait | Compte Twilio, financement et enregistrement expéditeur selon règles CI | Compte Infobip, canal SMS activé, essai puis activation commerciale |
| Accusés | Option DR documentée, à demander à l'équipe locale | Status callbacks (`delivered`/`undelivered`), à authentifier | Rapports de livraison/webhooks documentés, à authentifier |
| Débit/limites | 5 transactions/seconde ; achat maximal indiqué : 100 000 FCFA/jour/SIM | Limites du compte/expéditeur à confirmer | Limites du compte et routes à confirmer |
| « AZ Express » | Personnalisation gratuite sous approbation locale | Expéditeur alphanumérique préenregistré recommandé, contraintes CI à respecter ; nom exact à approuver | Expéditeur alphanumérique soumis aux règles/routes ; nom exact à approuver |

Le calcul Orange donne 7,25 FCFA/SMS pour 100 et 7,26 pour 1 000/10 000,
hors frais non précisés. La page générale affiche aussi un ancien résumé
« as low as 10 FCFA » : obtenir confirmation du tarif applicable au compte.
Validité des forfaits : 30/45/60 jours respectivement. Aucun achat effectué.
L'absence d'information sur un coût ne signifie pas qu'il est nul.

Sources :

- [Orange couverture et options](https://developer.orange.com/apis/sms-ci)
- [Orange tarifs et limites](https://developer.orange.com/apis/sms-ci/pricing)
- [Orange API et accusés](https://developer.orange.com/apis/sms-ci/api-reference)
- [Twilio règles CI](https://www.twilio.com/en-us/guidelines/ci/sms)
- [Twilio tarifs CI — montant non vérifié](https://www.twilio.com/en-us/sms/pricing/ci)
- [Twilio Messages REST](https://www.twilio.com/docs/messaging/api/message-resource)
- [Twilio états et callbacks](https://www.twilio.com/docs/messaging/guides/outbound-message-status-in-status-callbacks)
- [Infobip démarrage et couverture](https://www.infobip.com/docs/sms/get-started)
- [Infobip règles de couverture](https://www.infobip.com/docs/sms/sms-coverage-and-connectivity)
- [Infobip rapports de livraison](https://www.infobip.com/docs/sms/message-delivery)
- [ARTCI : mobiles CI à dix chiffres](https://artci.ci/en/faq/)

Normalisation : dix chiffres locaux commençant par 01, 05 ou 07, `+225` ou
`00225`. Anciens formats à huit chiffres, fixes et autres pays refusés.
Le préfixe ne constitue pas une preuve de l'opérateur actuel (portabilité).

## Adaptateur et secrets

`SmsProvider.send({to,body,idempotencyKey})` retourne un état normalisé parmi
`accepted`, `failed`, `simulated` ; exception/réponse inconnue = `unknown`.
`MockSmsProvider` n'effectue aucun appel réseau et ne conserve pas le message.
Le crochet `inspect` sert exclusivement aux assertions en mémoire des tests.
Le sélecteur d'adaptateur n'autorise le mock que dans l'émulateur Functions.
Hors émulateur, il retourne toujours un fournisseur indisponible : aucune API
réelle supposée et aucune simulation présentée comme un envoi réel.

Le pepper existant est lié via Secret Manager. Le builder accepte
`providerSecrets` pour les futurs `defineSecret` du fournisseur choisi ; aucun
secret fictif créé. Avant intégration réelle, lier aussi ces secrets au
déclencheur, lire leurs valeurs exclusivement côté serveur, ajouter un timeout
borné, valider la réponse, authentifier les DLR, filtrer tous les journaux et
étudier la rétention du contenu SMS chez le prestataire. Aucun secret Flutter.

## Prérequis et risques avant activation

L'activation est volontairement impossible pour un fournisseur réel dans cette
version. Il reste à sélectionner le fournisseur, approuver le prix et le nom
expéditeur, intégrer son adaptateur documenté et les DLR, vérifier les trois
réseaux et fixer les plafonds commerciaux. Ces étapes nécessitent validation.

Les drapeaux `DELIVERY_PROOFS_ENABLED` et `DELIVERY_SMS_ENABLED` doivent tous
deux être vrais côté serveur ; `DELIVERY_PROOFS_UI` et `DELIVERY_SMS_UI` côté
Flutter. Ils restent désactivés par défaut. `DELIVERY_SMS_PROVIDER=mock` n'est
honoré que si `FUNCTIONS_EMULATOR=true`. Aucun environnement réel modifié.

Les règles de destination protégée devront accompagner le futur déploiement
validé : ne pas activer les Functions seules avec les anciennes règles.
Configurer une rétention/suppression des numéros et historiques privés avant
production. Les accès Admin SDK restent de confiance. Le SMS n'est pas une
preuve cryptographique d'identité du destinataire : erreur de numéro, SIM
échangée/partagée, transfert volontaire et affichage sur écran verrouillé restent
des risques. La déclaration d'arrivée peut être prématurée. Les compteurs
limitent les dépenses mais ne suppriment pas les abus d'un client autorisé.

## Tests reproductibles et essais appareils

```text
node --test functions/test/deliveryProofSms.test.js functions/test/deliveryProofs.test.js functions/test/orderActions.test.js
flutter analyze --no-pub lib/delivery_proofs lib/screens/driver/driver_dashboard.dart test/delivery_proofs
flutter test --no-pub --dart-define=DELIVERY_PROOFS_UI=true --dart-define=DELIVERY_SMS_UI=true test/delivery_proofs
flutter test --no-pub test/delivery_proofs test/screens/customer_tracking_camera_throttle_test.dart test/screens/order_tracking_camera_throttle_test.dart test/services/delivery_order_service_test.dart
firebase emulators:exec --only firestore --project demo-az-express-qr "node --test --test-name-pattern=delivery_proofs rules-tests/firestore.rules.test.js"
git diff --check
```

Tous les tests SMS utilisent un mock, sans SMS réel. Les tests de règles
utilisent seulement Firestore Emulator. Les avertissements Firebase existants
sur la propriété `flutter` et les identifiants de projet d'émulateur n'ont pas
nécessité de modifier `firebase.json`.

Résultats locaux : 99 tests Node réussis (22 SMS, 23 preuves, 54 commandes),
15 tests Flutter réussis avec les drapeaux de test actifs, 32 réussis avec les
drapeaux absents et les régressions suivi/livraison, 4 tests de règles réussis.
Les cas spécifiques à un mode Flutter ne s'exécutent que dans ce mode ; ces
chiffres ne représentent pas 47 scénarios SMS distincts. Analyse ciblée : aucun
diagnostic. Syntaxe Node et `git diff --check` : PASS. Aucune valeur `.env`
reproduite dans les nouveaux fichiers, aucune journalisation brute dans les
modules SMS. Aucun test échoué au terme de cette intervention.

État Git final : branche `sync-windows-20260825`, modifications non indexées et
fichiers nouveaux non suivis. L'index n'a pas été modifié. Les fichiers déjà
modifiés avant cette phase (Hosting, `firebase.json`, `CLAUDE.md`, phase 1/2,
archives et documents existants) sont conservés. Les fichiers de phase 3 sont
énumérés au début de ce document ; aucune commande d'ajout, commit ou push.

Android et iPhone, après autorisation dans un environnement de test : vérifier
les trois parcours (soi/WhatsApp/SMS), le numéro enregistré, arrivée répétée,
reconnexion, fermeture/réouverture, expiration, absence de réception, renvoi
limité, ancien PIN refusé, cinq PIN erronés, QR remplacé, destinataire sans
Internet/application, changement d'affectation et commandes historiques.
Confirmer conservation GPS/photo/cash et absence de double règlement.
Les builds natifs et essais physiques ne sont pas exécutés dans cette phase.
Les tests réels sur Orange/MTN/Moov restent interdits jusqu'à validation explicite.
