# Procédure ciblée : suppression de compte + AZ IA (NON EXÉCUTÉE)

Aucune commande ci-dessous n'a été lancée. Chaque bloc exige une autorisation explicite. Projet `az-express-b0469`, région `europe-west1`. Ne pas redéployer les fonctions de paiement, de commande ni les 28 callables gardés.

## Périmètre exact (5 fonctions + règles)
| Fonction | Type | cpu | mémoire | maxInstances | concurrency | timeout |
|---|---|---|---|---|---|---|
| requestAccountDeletionCF | callable | 0,5 | 256 MiB | 1 | 1 | 120 s |
| getAccountDeletionStatusCF | callable | 0,25 | 256 MiB | 1 | 1 | 30 s |
| retryAccountDeletions | planifiée, toutes les 15 min | 0,25 | 256 MiB | 1 | 1 | 120 s |
| manageAccountDeletionCF | callable (super-admin) | 0,25 | 256 MiB | 1 | 1 | 120 s |
| azIaChat | callable | 1 | 512 MiB | 3 | 80 (défaut) | 120 s |

`cpu` et `maxInstances` sont maintenant explicites dans `functions/index.js` et `functions/azia/index.js` : un redéploiement remet à zéro les options non déclarées, et `azIaChat` n'avait aucun `maxInstances` dans le code alors que la production tourne à 3. Valeurs d'`azIaChat` = production actuelle (1 vCPU, 512 MiB, maxScale 3).

Σ(cpu×maxInstances) ajouté : 1,25 pour les 4 fonctions de suppression ; `azIaChat` ne change pas (3 × 1).

## 0. Pré-contrôles (lecture seule)
1. `git status` propre sur la branche `apple-resubmission-azia-consent`, options ci-dessus commitées.
2. `cd functions && npm test` (comparer au nombre de tests précédent) et `node -e "require('./index.js')"`.
3. `firebase functions:list --project az-express-b0469` : confirmer que les 4 fonctions de suppression sont absentes et `azIaChat` présente.
4. Quota : `gcloud run services list --project az-express-b0469 --region europe-west1 --format=json`, calculer `Σ(cpu×maxScale)`. Mesure du 29 octobre : 166,5 pour 95 services. Une erreur « total allowable CPU per project per region » apparue à ≈ 168 en septembre : la marge est quasi nulle. Si l'écart est insuffisant, ne pas insister : réduire d'abord des services secondaires (groupes B/C/D de `.claude/rules/firebase-functions.md`).
5. Sauvegarder la configuration réelle : `gcloud run services describe azIaChat ... --format=export > azIaChat.backup.yaml` et télécharger les règles actives.

## 1. Règles Firestore (seul `ai_consents` diffère du live)
```
firebase deploy --only firestore:rules --project az-express-b0469 --dry-run
firebase deploy --only firestore:rules --project az-express-b0469
```

## 2. AZ IA (avant les nouvelles applications)
```
firebase deploy --only functions:azIaChat --project az-express-b0469
```
Sans `--force`. Les anciennes applications perdent AZ IA (erreur générique) jusqu'à mise à jour. Contrôler ensuite `maxScale=3`, `cpu=1`, les deux secrets montés, puis un appel `consentAction:'status'` avec un compte fictif.

## 3. Suppression de compte (traitement toujours fermé)
```
firebase deploy --only functions:requestAccountDeletionCF,functions:getAccountDeletionStatusCF,functions:retryAccountDeletions,functions:manageAccountDeletionCF --project az-express-b0469
```
`operations_control/account_deletion` n'est PAS créé : toute demande reste `pending` (`server_rollout_not_enabled`) et l'application l'indique. Vérifier avec un compte fictif : la demande est enregistrée, rien n'est supprimé, aucun tombstone.
Si l'un des déploiements échoue sur le quota : arrêter, ne rien forcer.

## 4. Activation (action de production distincte, plus tard)
Créer `operations_control/account_deletion` avec `enabled:true, inventoryVersion:1` (client et livreur seulement) après décision de conservation des données. Retour arrière : `enabled:false`. Ne jamais lever un tombstone.

## Retour arrière
- Fonctions : redéployer la révision précédente depuis Cloud Run (`gcloud run services update-traffic`) pour `azIaChat` ; les 4 fonctions de suppression peuvent être supprimées tant que le drapeau est absent.
- Règles : republier le jeu sauvegardé.
