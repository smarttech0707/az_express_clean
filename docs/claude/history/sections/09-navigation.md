## Navigation

Situation actuelle : le web utilise `go_router` (`lib/web/web_router.dart`, avec redirections/guards), le mobile utilise `Navigator.push(context, AppTransitions.fadeSlide(...))` de façon directe dans les écrans — deux systèmes de navigation distincts, pas un seul unifié. Ne pas migrer le mobile vers `go_router` sans décision explicite. Pour toute nouvelle navigation mobile, rester cohérent avec le pattern `Navigator.push` + `AppTransitions` déjà en place plutôt que d'introduire un troisième système.

