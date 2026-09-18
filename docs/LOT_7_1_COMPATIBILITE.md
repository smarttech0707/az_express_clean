# LOT 7.1 — compatibilité et conditions de publication

Ce document ne déclenche aucune publication ni migration. Aucun tarif, identifiant
Firebase ou secret n'est changé par ce lot.

## Réservations et anciens clients

Le contrat de `createEventReservationCF` reste strict : `attemptId` est obligatoire,
associé au client et au contenu de la réservation. Une répétition retourne le
résultat déjà enregistré ; une réutilisation pour un autre contenu est refusée.
Les écritures directes de `event_reservations` restent interdites. Les commandes
directement payées par wallet gardent le contrôle `lastPaidOrderId`.

Une clé aléatoire générée par le serveur à chaque appel ancien ne dédupliquerait
pas les retries. Déduire une clé du seul panier fusionnerait deux réservations
intentionnelles identiques. Aucun de ces replis n'est ajouté.

Solution disponible : publier un client qui persiste la clé avant l'envoi et
réutilise cette clé après timeout, puis activer les restrictions après validation
de l'adoption, ou accepter explicitement le blocage des versions non compatibles.
Les fonctions doivent être disponibles en `europe-west1` avant la publication du
client qui les utilise. Si un ancien endpoint sans clé est déjà distribué, son
remplacement silencieux n'est pas une étape compatible : le propriétaire doit
décider des versions maintenues et du calendrier. Un endpoint versionné peut
séparer les contrats, mais ne rend pas l'ancien contrat sûr sans identifiant stable
fourni par son client. Aucun endpoint de contournement n'est créé dans ce lot.

`config/app_version` est un avertissement permissif : absence, lecture impossible
ou champ invalide ne bloque pas le paiement. Les anciens builds sans ce code ne
le consultent pas. Cash n'utilise pas ce contrôle. Il ne remplace pas une politique
de versions distribuées. Le numéro de build et le seuil restent à décider avant
publication ; ce lot ne les change pas arbitrairement.

## Artisans

La connexion historique reste acceptée et migre un compte individuellement dans
une transaction lorsqu'un PIN historique correct est présenté. Les credentials
privés existants restent prioritaires. Une divergence avec une valeur publique
résiduelle n'autorise jamais son écrasement par une migration.

Le script relit les deux documents dans une transaction par compte. Un état
partiel historique est nettoyé seulement après vérification de correspondance.
Les credentials invalides, divergents, ou manquants sur un compte approuvé sont
signalés sans suppression. Les erreurs/anomalies conduisent à un statut de sortie
non nul. Un dry-run peut annoncer des opérations à effectuer sans constituer un
échec ; `incomplete` reste alors explicite. Aucun identifiant ni secret ne figure
dans le résumé. L'inventaire à un instant donné ne couvre pas des créations futures.

L'approbation et le credential sont désormais validés ensemble par `setArtisanPin`
avec `approve: true`. Une répétition ne change pas le credential approuvé, même
après une réinitialisation. La réponse indique seulement si le PIN détenu par
l'administrateur est encore courant ; elle ne contient aucun PIN ni hash. Un
compte créé manuellement sans PIN reste en attente. Les comptes historiques déjà
approuvés mais incohérents nécessitent une réinitialisation explicite.

Une rotation explicite autorisée peut remplacer un credential divergent ; elle
est distincte d'une migration qui doit préserver les données. Deux rotations
simultanées sont sérialisées : la dernière transaction validée détermine le PIN.
Les anciens clients Admin SDK ne respectent pas les règles Firestore : il faut
retirer tous les anciens écrivains serveur avant de déclarer la transition sûre.

## Décisions préalables et retour arrière

- Inventorier en lecture seule les régions, fonctions et règles réellement
  déployées, ainsi que les versions client/admin distribuées.
- Décider si les migrations individuelles au login sont autorisées dès la
  publication des fonctions. Elles restent actives ; une politique différente
  exige une étape de compatibilité dédiée.
- Mettre à jour les administrateurs et bloquer la réintroduction des PIN publics
  avant toute migration groupée, après validation du dry-run et des anomalies.
- Les règles Firestore sont publiées en fichier complet : préparer et tester les
  rulesets intermédiaires sans rouvrir les protections financières.
- Le retour arrière doit conserver un lecteur de credentials privés et les
  reçus d'idempotence. Ne pas restaurer l'ancien login dépendant du PIN public,
  ne pas republier les PIN en clair et ne pas supprimer les reçus.
- Autoriser séparément chaque étape. Ce lot n'autorise ni déploiement, ni
  migration réelle, ni publication d'application.

Les tests d'émulateur utilisent uniquement des projets `demo-*` et un hôte local.
Leur appel programmatique au moteur de migration ne lance jamais le CLI de
migration ni un traitement sur le projet réel.
