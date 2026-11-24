## Marketplace — état réel vs. vision "place de marché intelligente"

Ce qui existe déjà et fonctionne : recherche/filtre produits (`MpService.search()`), favoris (`marketplace_favorites`), signalement d'abus (`marketplace_reports` — abus uniquement, pas des avis), **et une messagerie acheteur↔vendeur dédiée** (`lib/marketplace/screens/mp_chat_page.dart`, collection `marketplace_chats/{chatId}/messages`, texte + vocal) — c'est déjà plus riche que ce qu'on pourrait supposer.

Écarts réels vérifiés (aucun n'est construit aujourd'hui, à prioriser explicitement plutôt qu'à supposer résolus) :
- **Pas de panier** : le parcours va directement de la fiche produit au contact vendeur (appel/message/WhatsApp) — pas de panier multi-articles/multi-vendeurs, pas de checkout.
- **Pas d'avis/notes** pour produits ou vendeurs — `marketplace_reports` ne sert qu'au signalement d'abus, pas à la notation. Le `RatingDialog` générique existe (`lib/widgets/rating_dialog.dart`) mais n'est utilisé nulle part dans le Marketplace.
- **Pas de profil boutique** : la collection `sellers` n'a que `name/phone/type/isActive/wallet` — pas de logo, bannière, horaires, description, position GPS de boutique.
- **Catégories codées en dur** : `lib/marketplace/mp_constants.dart` (liste Dart fixe : téléphones/tablettes/ordinateurs/accessoires) — pas de collection Firestore `marketplace_categories`, donc pas administrable sans redéploiement, malgré la demande explicite du prompt.
- **Pas d'écran de modération admin** pour le Marketplace — aucun admin ne peut aujourd'hui suspendre un vendeur, supprimer une annonce frauduleuse ou traiter les `marketplace_reports` depuis une UI dédiée.
- **Pas de variantes générique ni de vidéo produit** — seulement des champs plats spécifiques téléphone (`storage/ram/color/battery`), images uniquement.

Chacun de ces écarts est un chantier séparé (panier+checkout, avis/notation, profil boutique, catégories pilotées par Firestore, modération admin, variantes/vidéo) — ne pas les construire silencieusement, faire prioriser explicitement.

