## Documentation

`CLAUDE.md` est déjà, de fait, la documentation technique vivante du projet — architecture Flutter/Backend/Firebase/AZ IA/Wallet, schéma Firestore réel, RBAC, intégrations, outils AZ IA et leurs limites, conventions : tout existe déjà ici, construit section par section au fil des prompts précédents (01→18), pas dans un dossier `docs/` séparé (qui n'existe pas — seuls `CLAUDE.md` et le `README.md` boilerplate existent à la racine). C'est la réponse principale à la demande de ce prompt, pas un point de départ.

**Tension à ne pas trancher seul** : ce prompt demande une docstring pour "chaque classe/méthode/service/repository/controller/provider/API/Cloud Function". Ça contredit directement la règle déjà actée section Qualité de code (« documenter le POURQUOI... pas reformuler ce que le code montre déjà ») — qui reflète aussi une préférence système plus large pour du code lisible plutôt que des commentaires exhaustifs. Ne pas trancher unilatéralement en faveur de l'un ou l'autre : si l'utilisateur veut vraiment des docstrings systématiques partout, c'est un changement de politique à valider explicitement, pas une extension silencieuse de la charte existante.

Ce qui manque réellement et n'est pas déjà couvert par `CLAUDE.md` :
- **Pas de documentation par endpoint** (objectif/paramètres/validation/réponses/erreurs/permissions/exemples pour chacune des ~35 Cloud Functions) — `CLAUDE.md` documente les *conventions* (section API), pas chaque fonction individuellement ; décision déjà actée de ne pas versionner l'API sans besoin concret.
- **Pas de changelog structuré** — l'historique vit dans `git log` (source de vérité normale) et la mémoire de session, pas dans un fichier `CHANGELOG.md`.
- **Pas de guides de formation séparés par rôle** (développeur/admin/support/partenaire).
- **Pas de procédures de publication Android/iOS ni de rollback documentées** — cohérent avec le constat déjà fait section DevOps (déploiement manuel, pas de procédure écrite).
- **Pas de schémas visuels** — tout est en texte dans `CLAUDE.md`.

Construire tout ça (surtout la documentation exhaustive par fonction/méthode) est disproportionné en réponse à une charte — même limite que pour Tests & QA et DevOps. Si une priorité doit émerger, elle doit être choisie explicitement.

