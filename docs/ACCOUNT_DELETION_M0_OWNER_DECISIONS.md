# Mission M0 — Décisions du propriétaire AZ Express (Q1 à Q12)

Document de préparation, **sans aucune autorisation d'implémentation**. Source : `docs/ACCOUNT_DELETION_L4_10_6_DECISION_MATRIX.md` (référence) et `docs/ACCOUNT_DELETION_L4_10_5_TECHNICAL_PLAN.md`. Aucun accès Firebase, boutique d'applications ou production : tout ce qui dépend d'eux est marqué **[À vérifier]**. Les options ci-dessous sont celles du rapport ; rien n'est ajouté. **[R]** = recommandation du rapport.

## 1. Décisions déjà acquises (aucun revote)

| Réf. | Décision |
|---|---|
| D2-bis | Connexion par téléphone + mot de passe, vérifiée côté serveur, e-mail jamais exposé |
| D2 | Étude juridique/métier des numéros publics avant toute suppression |
| D2 inscription | Réponse uniforme si un numéro est déjà utilisé |
| D3 | OTP, PIN ≥ 6 chiffres, verrouillage progressif par profil |
| Récupération artisan | Support + administrateur, avec traçabilité |
| D5 | Amélioration du mécanisme de version minimale existant |
| Transition | 30 jours à partir de T0 (version complète disponible sur tous les canaux) |
| App Check | Étude séparée |

**Conflit à signaler (déjà identifié en L4.10.6)** : « réponse uniforme » à l'inscription est incompatible avec une connexion automatique immédiate. La décision reste valable ; seule sa mise en œuvre est tranchée par la **Q4**. Aucune autre question n'entre en contradiction avec les décisions acquises.

## 2. Les 12 questions

Légende « Obligatoire » : **Oui** = bloque une mission ; **Non** = peut être tranchée plus tard.

---

### Question 1 — Jetons personnalisés et clé API Web
**Formulation exacte** : « Accepter la création de `clientPhoneLogin` avec **clé API Web fournie en configuration** et la nécessité d'un rôle de signature pour les jetons personnalisés (validation de faisabilité d'abord) ? »

**En clair** : pour que le serveur vérifie le mot de passe sans montrer l'e-mail (D2-bis), il doit interroger le service d'identification de Firebase avec la clé publique de l'application, puis délivrer au téléphone une « clé d'ouverture de session » (jeton personnalisé). Cela demande une permission de signature pour le compte technique des fonctions.

| Option | Signification | Avantages | Inconvénients |
|---|---|---|---|
| Accepter (sous réserve de faisabilité) | Une fonction `clientPhoneLogin` sera créée si la faisabilité est prouvée | Comptes et identifiants conservés ; e-mail jamais exposé | Permission IAM à ajouter ; risque que la session par jeton personnalisé casse certaines fonctions (ex. ré-authentification par e-mail) |
| Refuser | Le principe n'est pas retenu | Aucune nouvelle permission | Contredit D2-bis ; la fuite d'e-mail de `checkClientPhone` ne peut pas être fermée |

**Conséquences** : clients (connexion par téléphone) et vendeurs (même écran) ; livreurs/artisans non concernés. **[R]** : accepter sous condition de la mission de faisabilité locale (M1). **À vérifier avant** : comportement des jetons, du REST d'identification et des sessions — **[À vérifier]**, non vérifiable sans essai. **Obligatoire : Oui** (bloque M1 et M3).

- Décision du propriétaire :
- Commentaire :
- Validation :

---

### Question 2 — Contrat de `checkClientPhone` pendant la transition
**Formulation exacte** : « Pendant la transition, conserver le contrat actuel de `checkClientPhone` (fuite d'e-mail) ou imposer une mesure compensatoire plus stricte (au risque de casser les anciennes versions) ? »

**En clair** : cette fonction dit aujourd'hui si un numéro existe et renvoie l'e-mail du compte. Les anciennes versions de l'application en dépendent pour se connecter.

| Option | Signification | Avantages | Inconvénients |
|---|---|---|---|
| Conserver le contrat actuel | La fuite d'e-mail continue 30 jours | Aucune casse de connexion pour les anciens clients | Risque d'énumération maintenu pendant la transition |
| Mesure compensatoire plus stricte | Durcir tout de suite | Réduit la fuite plus tôt | Peut empêcher des clients d'anciennes versions de se connecter (nombre inconnu) |

**Conséquences** : clients et vendeurs sur anciennes versions. **[R]** : conserver le contrat, combiné à la mesure de la Q3. **À vérifier** : part des anciennes versions — **[À vérifier]** (mesurable seulement après la version minimale). **Obligatoire : Oui** (bloque M3).

- Décision du propriétaire :
- Commentaire :
- Validation :

---

### Question 3 — Mesure compensatoire minimale pendant 30 jours
**Formulation exacte** : « Mesure compensatoire minimale acceptable pendant 30 jours (limites par appelant et par numéro) ? »

**En clair** : limiter le nombre d'essais pour rendre l'énumération des numéros lente, sans changer ce que la fonction répond.

| Option | Signification | Avantages | Inconvénients |
|---|---|---|---|
| Limites par appelant et par numéro (option du rapport) | Plafonds d'appels par session et par numéro | Aucune casse ; ralentit les abus | Un attaquant peut multiplier les sessions anonymes ; seuils chiffrés non fournis par le rapport |

**Conséquences** : un titulaire ne doit jamais être bloqué durement par un tiers (ralentissement, pas verrou). **[R]** : valider le principe ; chiffrer les seuils dans M3. **Vérification** : tests des compteurs. **Obligatoire : Oui, le principe** (les seuils viennent en M3).

- Décision du propriétaire :
- Commentaire :
- Validation :

---

### Question 4 — Inscription : OTP ou réponse uniforme sans connexion automatique
**Formulation exacte** : « Inscription : OTP avant toute information, ou réponse uniforme sans connexion automatique ? »

**En clair** : pour ne pas révéler qu'un numéro est déjà utilisé (décision acquise), il faut soit prouver que la personne possède le numéro (code SMS), soit répondre pareil dans tous les cas et ne pas la connecter d'office.

| Option | Signification | Avantages | Inconvénients |
|---|---|---|---|
| (a) OTP avant toute information | Code SMS d'abord ; le « déjà utilisé » n'est dit qu'au détenteur du numéro | Sécurité et expérience conservées | Dépend de Phone Auth ; coût SMS ; panne signalée dans le code **[À vérifier]** ; le téléphone ne doit pas devenir un moyen de connexion |
| (b) Réponse identique sans connexion automatique | Message unique « demande reçue, connectez-vous ou récupérez votre accès » | Uniforme, sans SMS | Une étape de plus pour le nouveau client ; risque d'incompréhension |

**Conséquences** : nouveaux clients. **[R]** : (b) si Phone Auth n'est pas fiable ; (a) s'il est confirmé stable. **À vérifier avant** : Q12. **Obligatoire : Oui** (bloque M4).

- Décision du propriétaire :
- Commentaire :
- Validation :

---

### Question 5 — Paramètres du verrou, contestation, double validation (artisans)
**Formulation exacte** : « Artisans : valeurs du verrou progressif, durée de la fenêtre de contestation (72 h ?), double validation pour quels cas ? »

**En clair** : combien d'essais de PIN avant blocage, pendant combien de temps l'ancien titulaire peut contester une reprise, et quand un second administrateur doit valider.

| Élément | Valeurs d'exemple du rapport | Remarque |
|---|---|---|
| Verrou progressif | 5 échecs ⇒ 1 min ; 7 ⇒ 30 min ; 10 ⇒ 24 h | Trop strict : artisans bloqués ; trop lâche : force brute |
| Fenêtre de contestation | 72 h | |
| Double validation | profil déjà lié à un autre appareil ; numéro changé récemment ; profil vérifié/à fort volume ; contestation en cours ; demande hors heures | Un second administrateur distinct du demandeur et du premier approbateur |

**Conséquences** : artisans (accès), support et administrateurs (charge). **[R]** : adopter ces valeurs comme point de départ, ajustables. **Vérification** : aucune. **Obligatoire : Oui** (bloque M5).

- Décision du propriétaire :
- Commentaire :
- Validation :

---

### Question 6 — Rôles de récupération et vérification en personne
**Formulation exacte** : « Artisans : qui est le "support" (personnes, permission `support`) et qui approuve (permission `services`, super) ? Vérification en personne obligatoire pour quels cas ? »

**En clair** : nommer qui ouvre une demande de récupération (support), qui l'approuve (administrateur `services` ou super), et pour quels cas l'artisan doit venir en personne à Abengourou.

| Option du rapport | Détail |
|---|---|
| Le support ouvre la demande et collecte les preuves | permission existante `support` |
| Un administrateur approuve | permission `services` ou super |
| Vérification en personne pour les cas sensibles | pièce d'identité contrôlée, non conservée dans le système |

**Séparation des responsabilités** : l'administrateur ne choisit ni ne connaît le PIN du titulaire et ne modifie pas le numéro ; le titulaire choisit son nouveau PIN après OTP. **Risque** : petit effectif ⇒ séparation difficile. **[R]** : vérification en personne pour les cas listés en Q5. **Obligatoire : Oui** (bloque M5).

- Décision du propriétaire :
- Commentaire :
- Validation :

---

### Question 7 — PIN ≥ 6 : changement forcé
**Formulation exacte** : « PIN ≥ 6 : changement forcé au prochain login pour tous les artisans ? »

**En clair** : les anciens PIN de 4 ou 5 chiffres ne sont pas identifiables (seul leur haché est stocké). On ne peut le constater qu'à la saisie d'une connexion réussie.

| Option | Signification | Avantages | Inconvénients |
|---|---|---|---|
| Oui, changement forcé à la prochaine connexion réussie (après OTP) | Tous passent à 6 chiffres | Sécurité homogène | Artisans bloqués si l'OTP ne fonctionne pas |
| Non | Anciens PIN conservés | Aucune friction | Contredit D3 (PIN ≥ 6) |

**[R]** : oui, avec un délai de grâce borné. **À vérifier avant** : Q12. **Obligatoire : Oui** (bloque M5).

- Décision du propriétaire :
- Commentaire :
- Validation :

---

### Question 8 — Appareils non mis à jour
**Formulation exacte** : « Utilisateurs sur appareils non mis à jour : maintien d'un mode lecture ou blocage total ? Appareils < Android 7.0 / iOS 13 ? »

| Option | Signification | Avantages | Inconvénients |
|---|---|---|---|
| Mode lecture | Consultation possible, pas d'écriture | Utilisateur non exclu totalement | Travail supplémentaire pour distinguer lecture et écriture |
| Blocage total | Plus d'accès à la fin de la transition | Simple | Exclut les appareils trop anciens (Android < 7.0 / iOS < 13) |

**Conséquences** : tous les rôles sur appareils anciens (nombre inconnu **[À vérifier]**). **Obligatoire : Oui** (bloque M2 et M8). Pas de recommandation chiffrée dans le rapport ; il signale que le blocage total est plus simple.

- Décision du propriétaire :
- Commentaire :
- Validation :

---

### Question 9 — Origine de T0 et canaux
**Formulation exacte** : « Origine de T0 : quels canaux doivent être à jour (Play, App Store, APK direct) et quel suivi de part de version est accepté ? »

**En clair** : le délai de 30 jours ne démarre que lorsque la nouvelle version est disponible partout où elle est utilisée.

| Canal | Remarque |
|---|---|
| Google Play | utilisé (AAB 1.0.x) |
| APK direct (`/telecharger`) | signature différente de Play |
| App Store | publication **[À vérifier]** |

Suivi de version : report anonymisé `{rôle, plateforme, build}`, tableau de bord administrateur, alerte à J-7. **Risque** : un canal en retard repousse T0. **[R]** : lister les canaux réellement utilisés et accepter ce suivi. **Obligatoire : Oui** (bloque M2 et M8).

- Décision du propriétaire :
- Commentaire :
- Validation :

---

### Question 10 — Dépendances nouvelles
**Formulation exacte** : « Dépendances nouvelles autorisées (`package_info_plus`, `in_app_update`) ou conservation du numéro de build injecté ? »

| Option | Signification | Avantages | Inconvénients |
|---|---|---|---|
| Autoriser `package_info_plus` | Lire la version depuis l'application installée | Moins d'oubli à la compilation | Nouvelle dépendance à maintenir |
| Autoriser `in_app_update` | Mise à jour dans l'application (Google Play uniquement) | Meilleure expérience Play | Inutile pour APK direct et iOS ; nouvelle dépendance |
| Conserver le numéro injecté | `APP_BUILD_NUMBER` fourni au build | Aucune dépendance | Risque d'oubli ; aujourd'hui absent du script de build, défaut 0 ⇒ jamais bloqué |

**[R]** : conserver le numéro injecté, rendu obligatoire dans le script de build ; `in_app_update` différé ; `package_info_plus` possible comme contrôle croisé. **Obligatoire : Oui** (bloque M2).

- Décision du propriétaire :
- Commentaire :
- Validation :

---

### Question 11 — Numéros publics
**Formulation exacte** : « Numéros publics : qui mène l'étude juridique, et quel arbitrage entre appel direct et alternatives (§5) ? »

| Option du rapport (L4.10.5 §5, non retenues à ce stade) | Remarque |
|---|---|
| Numéro exposé seulement aux participants d'une commande active | Nécessite une fonction serveur |
| Numéros d'établissement distincts des numéros personnels (livreur) | |
| Appel/chat dans l'application ou numéro intermédiaire | Coût et couverture à étudier |
| Statu quo documenté avec consentement explicite | |

**Conséquences** : toute restriction casse les boutons d'appel clients → livreurs/pharmacies/artisans tant qu'une alternative n'existe pas. Aucune suppression ni masquage immédiat (décision acquise). **[R]** : mission documentaire, menée par un juriste ou conseil désigné ; aucune décision technique avant ses conclusions. **Obligatoire : Non pour les autres missions** ; **Oui pour M6**.

- Décision du propriétaire (responsable de l'étude, délai) :
- Commentaire :
- Validation :

---

### Question 12 — Statut réel de Phone Auth et de l'App Store
**Formulation exacte** : « Statut réel de Phone Auth en production et de l'App Store (iOS) à fournir par le propriétaire. »

**En clair** : informations factuelles que seul le propriétaire peut donner. Elles conditionnent Q4, Q7 et l'OTP des artisans. Un message d'erreur Phone Auth (`INTERNAL (13) / 39`) est signalé dans le code ; son état actuel est **[À vérifier]**. Fiabilité des SMS en Côte d'Ivoire : **non vérifiée** (aucun accès autorisé).

À fournir : Phone Auth fonctionne-t-il aujourd'hui ? quotas/coûts SMS ? réception effective chez les opérateurs ivoiriens ? l'application est-elle publiée sur l'App Store ? quelles versions sont en ligne sur Play, App Store et `/telecharger` ?

**Obligatoire : Oui** (priorité 1 ; bloque Q4, Q7, M5).

- Décision / information du propriétaire :
- Commentaire :
- Validation :

---

## 3. Tableau récapitulatif

| Q | Sujet | Options | [R] du rapport | Obligatoire | Débloque |
|---|---|---|---|---|---|
| 1 | Jetons personnalisés / clé Web | accepter sous réserve ; refuser | accepter sous réserve (M1) | Oui | M1, M3 |
| 2 | Contrat `checkClientPhone` | conserver ; durcir | conserver | Oui | M3 |
| 3 | Mesure compensatoire | limites appelant+numéro | valider le principe | Oui | M3 |
| 4 | Inscription | OTP ; réponse uniforme sans connexion auto | (b) si Phone Auth peu fiable | Oui | M4 |
| 5 | Verrou / contestation / double validation | valeurs d'exemple | les adopter | Oui | M5 |
| 6 | Rôles de récupération | support ouvre, admin approuve, présence | selon liste Q5 | Oui | M5 |
| 7 | PIN ≥ 6 forcé | oui ; non | oui, délai de grâce | Oui | M5 |
| 8 | Appareils anciens | lecture ; blocage total | non précisée | Oui | M2, M8 |
| 9 | Canaux de T0 | Play, App Store, APK direct | lister les canaux utilisés | Oui | M2, M8 |
| 10 | Dépendances | 2 paquets ; numéro injecté | numéro injecté obligatoire | Oui | M2 |
| 11 | Numéros publics | 4 alternatives | étude juridique d'abord | Pour M6 | M6 |
| 12 | Phone Auth / App Store | information factuelle | — | Oui (priorité 1) | Q4, Q7, M5 |

## 4. Vérifications encore nécessaires (non faites)

- Faisabilité des jetons personnalisés, du REST de vérification de mot de passe, des sessions et revendications (M1, d'abord en local ; le réel exige un environnement autorisé).
- Statut de Phone Auth et fiabilité des SMS en Côte d'Ivoire (information du propriétaire).
- Publication sur l'App Store, versions en ligne par canal.
- Contenu de `config/app_versions` et du fichier de variables de build (non lus).
- Part des anciennes versions et des appareils < Android 7.0 / iOS 13.
- Nombre de doublons de numéros et de profils artisans hérités.
- Avis juridique sur les numéros publics.

## 5. Décisions bloquantes

Priorité 1 : **Q12, Q9**. Priorité 2 : **Q10, Q1, Q2, Q3**. Priorité 3 : **Q4, Q5, Q6, Q7, Q8** (Q4 dépend de Q12). Q11 ne bloque que M6.

## 6. Conditions pour autoriser la prochaine mission

- **M1 (faisabilité locale)** : Q1 tranchée.
- **M2 (version minimale)** : Q8, Q9, Q10 tranchées ; autorisation explicite de modifier Flutter et les scripts de build (la donnée `config/app_versions` exige une autorisation séparée).
- **M3** : M1 terminée + Q2, Q3 ; accord spécifique pour `index.js` (fichier protégé).
- **M4** : M1 + Q4 (donc Q12).
- **M5** : M1 + Q5, Q6, Q7, Q12 ; accord spécifique pour `passwordReset.js` (fichier protégé).
- **M6** : Q11.

Chaque mission demande **sa propre autorisation écrite** ; rien dans ce document n'autorise une implémentation, un test, un build, un déploiement ou un accès aux environnements Firebase.
