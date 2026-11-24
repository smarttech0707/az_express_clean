# LOT 7.5 — diagnostic local des transactions artisans

## État initial et provenance

Branche `sync-windows-20260825`, HEAD `d99137f` confirmés. Toutes les différences
du LOT 7.4, les références de production et les règles intermédiaires ont été
préservées. Aucun appel à la production ni modification des règles.

`artisanAccounts.js` contient la phase A et sa lecture groupée identifiées dans
le travail précédent. Les modifications non attribuées de
`artisanCredentials.js` remplacent deux lectures par `tx.getAll` dans
`migrateProvider` et `setPin`. `test/migrateArtisanPins.test.js` adapte seulement
le faux Firestore à cette signature. Ni les décisions métier ni l'ensemble des
documents lus/écrits ne changent. Le retour de getAll conserve l'ordre des refs.

L'auteur et l'outil ayant produit ces deux changements ne sont pas établis :
un diff non commité et des dates de modification ne constituent pas une preuve
d'attribution. Les changements ont été examinés et testés indépendamment,
sans être supprimés ni présentés comme un correctif prouvé de l'erreur historique.

## Diagnostic

Environnement observé : Node 24.15.0, firebase-admin 12.7.0,
@google-cloud/firestore 7.11.6, Firestore Emulator 1.21.0, Java 21, locale en_US.
Les tests ne prouvent pas le comportement du runtime Node 22 de production.

Les timeouts de verrouillage sont reproductibles. Les traces montrent des
callbacks transactionnels rejoués et finalement un seul commit d'approbation.
L'erreur exacte `INVALID_ARGUMENT: Transaction is invalid or closed` n'a pas été
reproduite dans cette campagne. Aucun test ne permet donc d'attribuer avec
certitude son origine initiale au métier, au SDK ou à l'émulateur.

Le code local du SDK (`transaction.js`, `isRetryableTransactionError`) confirme
que ABORTED est rejouable. INVALID_ARGUMENT ne l'est que si le message contient
`transaction has expired`, pas `Transaction is invalid or closed`.
Cette différence explique la propagation de l'erreur lorsqu'elle survient,
mais pas pourquoi l'émulateur ferme précisément cette transaction.

Les expériences comparent les mêmes approbations, avec lectures séquentielles
ou groupées, sans délai puis avec un délai de 4 s sur la première tentative
(deux appels ou seulement un appel). Aucun délai n'est ajouté au métier.
Les traces ne contiennent ni PIN, ni hash, ni contenu de document.

## Correction démontrée et limites

Un défaut distinct du banc de tests est démontré par un test à promesses
contrôlées : Promise.all rejette avant la fin d'un autre écrivain. Le prochain
beforeEach pouvait donc nettoyer les données alors qu'une transaction du test
précédent restait active. Les courses artisan/login utilisent désormais
`settleConcurrent` : attendre toutes les opérations puis propager toutes les
erreurs dans AggregateError. Aucun réessai, aucune conversion en succès.
Les limites externes de durée restent nécessaires pour les opérations bloquées.

Les commentaires qui affirmaient que getAll rendait nécessairement les conflits
rejouables ont été corrigés. Aucun changement métier spéculatif n'a été ajouté.
Les lectures groupées préexistantes sont conservées et leurs invariants sont
testés. Le défaut du banc de tests ne constitue pas une preuve de la cause
initiale de l'erreur Firestore.

## Campagnes

Tous les processus de test ont une limite externe via
`spawnSync(process.execPath, args, { timeout: limiteMs, encoding: 'utf8' })`.
Un exit non nul, une annulation ou ETIMEDOUT n'est jamais compté comme réussite.

| Campagne | Exécutions | Limite par processus | Résultat |
|---|---|---|---|
| Approbations initiales | 1, 2, 3, 4, 5 | 45 s | 1/1 à chaque passage |
| Diagnostic sans délai, séquentiel | 1, 2, 3 | 45 s | 1/1 à chaque passage |
| Diagnostic sans délai, groupé | 1, 2, 3 | 45 s | 1/1 à chaque passage |
| Délai 4 s des deux appels, séquentiel | 1, 2, 3 | 45 s | 1/1 à chaque passage |
| Délai 4 s des deux appels, groupé | 1, 2, 3 | 45 s | 1/1 à chaque passage |
| Délai 4 s d'un appel, séquentiel | 1, 2, 3 | 45 s | 1/1 à chaque passage |
| Délai 4 s d'un appel, groupé | 1, 2, 3 | 45 s | 1/1 à chaque passage |
| Artisan complet avant correction du banc | 1, 2, 3 | 120 s | 14/14 à chaque passage |
| Phase A avant correction du banc | 1, 2, 3 | 120 s | 10/10 à chaque passage |
| Unitaires avant correction du banc | 1 | 60 s | 19/19 |
| Règles intermédiaires | 1 | 60 s | 33/33 |
| Unitaires après correction du banc | 1 | 60 s | 21/21 |
| Artisan complet après correction du banc | 1, 2, 3 | 120 s | 14/14 à chaque passage |
| Phase A après correction du banc | 1, 2, 3 | 120 s | 10/10 à chaque passage |

Aucun échec, timeout externe ni test annulé dans ce lot. Les timeouts de verrou
internes ont été traités par les réessais normaux du SDK ; ils ne sont pas des
annulations des processus de test. Syntaxe JavaScript et `git diff --check` OK.
`firestore.rules` est inchangé par rapport à HEAD. L'empreinte des règles
intermédiaires reste `9982da897ad0dd6640bd5c9821fcc98c68eb182e618379659a0000ba7bd55b3f`.

Les tests de migration n'opèrent que sur des fixtures de l'émulateur `demo-lot71`.
Aucun script de migration réel n'est lancé. Les autres projets sont
`demo-lot74`, `demo-lot74-rules`, `demo-lot75`, tous sur 127.0.0.1:8187.

## Reproduction

Démarrer le JAR local avec les arguments JVM entre apostrophes sous PowerShell :

```powershell
java '-Duser.language=en' '-Duser.country=US' -jar "$env:USERPROFILE\.cache\firebase\emulators\cloud-firestore-emulator-v1.21.0.jar" --host 127.0.0.1 --port 8187 --project_id demo-lot75
```

Exemple de campagne bornée depuis la racine, dans une seconde console :

```powershell
$env:FIRESTORE_EMULATOR_HOST = '127.0.0.1:8187'
@'
const { spawnSync } = require('node:child_process');
let failures = 0;
for (let run = 1; run <= 3; run++) {
  for (const file of [
    'functions/test-emulator/artisanAccounts.test.js',
    'functions/test-emulator/artisanLoginPhaseA.test.js',
    'functions/test-emulator/artisanApprovalConcurrency.test.js',
  ]) {
    const result = spawnSync(process.execPath, ['--test', file], {
      encoding: 'utf8', timeout: 120000,
    });
    console.log(JSON.stringify({ run, file, exit: result.status,
      timeout: result.error?.code === 'ETIMEDOUT' }));
    console.log(result.stdout);
    if (result.stderr) console.error(result.stderr);
    if (result.status !== 0) failures++;
  }
}
process.exitCode = failures ? 1 : 0;
'@ | node -
```

Le diagnostic utilise par défaut les lectures groupées réelles.
Pour le témoin séquentiel, définir `ARTISAN_READ_DIAGNOSTIC=sequential`.
Le délai facultatif `ARTISAN_READ_DELAY_MS=4000` reste limité à la première
tentative ; `ARTISAN_DELAY_ONE=1` le limite à l'appel A.

Verdict : BLOCKED sur l'objectif de correction de la cause historique, qui reste
non démontrée. Aucun GO de déploiement. La phase B n'est pas activée.
