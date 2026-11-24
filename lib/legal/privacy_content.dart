/// Source unique des textes de confidentialité (mission M2.9).
///
/// Cette seule définition alimente : la page web Flutter (`WebPrivacyPage`), le texte affiché dans l'application
/// (Profil), et les pages statiques `web/legal/confidentialite.html` et `web/legal/delete-account.html` (générées par
/// `tool/generate_legal_html.dart`, vérifiées par `test/legal/privacy_content_test.dart`).
/// Fichier Dart pur (aucun import Flutter) pour pouvoir être exécuté par l'outil de génération.
///
/// Règles : aucune durée légale, adresse institutionnelle ou fournisseur n'est inventé ici. Ce qui n'est pas arrêté
/// est écrit comme tel (« à confirmer »). Les exceptions de conservation sont identifiées mais PAS validées
/// juridiquement.
library;

enum LegalBlockKind { paragraph, list, callout }

class LegalBlock {
  const LegalBlock._(this.kind, this.text, this.items);

  /// Paragraphe. `**gras**` est le seul balisage admis.
  const LegalBlock.p(String text) : this._(LegalBlockKind.paragraph, text, const []);

  /// Liste à puces.
  const LegalBlock.ul(List<String> items) : this._(LegalBlockKind.list, '', items);

  /// Encadré mis en avant.
  const LegalBlock.callout(String text) : this._(LegalBlockKind.callout, text, const []);

  final LegalBlockKind kind;
  final String text;
  final List<String> items;
}

class LegalSection {
  const LegalSection(this.title, this.blocks);
  final String title;
  final List<LegalBlock> blocks;
}

class LegalContact {
  LegalContact._();

  /// Adresse de contact EXISTANTE (personnelle). Une adresse institutionnelle reste à décider par le propriétaire :
  /// la changer ici suffit pour mettre à jour tous les supports.
  static const email = 'znm0905@gmail.com';
  static const whatsapp = '+225 07 98 05 13 97';
  static const place = 'Abengourou / Abidjan, Côte d\'Ivoire';
  static const deleteAccountPath = '/delete-account';
  static const deleteAccountDisplay = 'az-express-b0469.web.app/delete-account';
  static const siteDisplay = 'az-express-b0469.web.app';
}

class PrivacyContent {
  PrivacyContent._();

  static const lastUpdated = '12 novembre 2026';

  /// Délai cible décidé par le propriétaire.
  static const deletionDelayDays = 30;

  static const durationsNotice =
      'Elles ne sont pas encore arrêtées : elles sont à confirmer et seront '
      'publiées ici dès leur validation. Nous ne promettons aucune durée avant cela. Ces exceptions ont été '
      'identifiées mais n\'ont pas encore été validées juridiquement.';

  /// Données supprimées ou anonymisées à la suppression du compte.
  static const deletedData = [
    'Profil et coordonnées : nom, téléphone, e-mail, adresses, position, photo de profil, pièces d\'identité enregistrées.',
    'Jetons de notification et notifications.',
    'Photos personnelles stockées (dont le selfie d\'acceptation des livreurs).',
    'AZ IA : historique de conversation, mémoire, rappels et demandes non confirmées.',
    'Nom, téléphone et adresses des commandes terminées auxquelles vous étiez rattaché.',
    'Votre compte de connexion (il n\'est plus possible de se reconnecter).',
  ];

  /// Informations qui ne sont pas supprimées avec le compte (exceptions à valider).
  static const keptData = [
    'Soldes, transactions du portefeuille, montants et commissions des commandes (obligations comptables).',
    'Preuves de livraison (litiges).',
    'Trace de votre consentement à AZ IA et opérations confirmées avec AZ IA.',
    'Journaux de sécurité et dossier technique de la suppression (prévention de la fraude, preuve du traitement).',
    'Sauvegardes et journaux techniques de l\'infrastructure (Firebase / Google) : durée propre à ces services, à confirmer.',
    'Mesures d\'usage et rapports de plantage (Firebase Analytics, Crashlytics) : durée de conservation à confirmer.',
  ];

  static const deletionBlockedCases =
      'La suppression est refusée tant qu\'un solde de portefeuille, une dette, un règlement en attente ou une course en '
      'cours subsiste : régularisez d\'abord, puis renouvelez la demande.';

  /// Règle des 30 jours, par type de compte (mission M2.11). Le point de départ pour les partenaires n'est PAS décidé.
  static const deletionDelayBlocks = <LegalBlock>[
    LegalBlock.p(
        '**Comptes ordinaires :** les données personnelles concernées sont supprimées ou anonymisées **au plus tard '
        '$deletionDelayDays jours après votre demande**, sous réserve des exceptions ci-dessous.'),
    LegalBlock.p(
        '**Comptes bloqués :** si la suppression est impossible (solde de portefeuille, dette, règlement en attente ou '
        'course en cours), la demande est refusée ou suspendue. Après régularisation, vous devez renouveler votre '
        'demande ; le délai de $deletionDelayDays jours court alors **à compter de cette nouvelle demande**.'),
    LegalBlock.p(
        '**Comptes partenaires :** la demande fait l\'objet d\'un examen préalable par l\'équipe AZ Express. Le point '
        'de départ du délai de $deletionDelayDays jours pour ces comptes reste à préciser et à valider.'),
  ];

  static const sections = <LegalSection>[
    LegalSection('1. Introduction', [
      LegalBlock.p(
          'AZ Express (« nous ») s\'engage à protéger la vie privée de ses utilisateurs. Cette politique explique '
          'comment nous collectons, utilisons, partageons et protégeons vos informations lorsque vous utilisez '
          'l\'application mobile AZ Express et notre site web.'),
    ]),
    LegalSection('2. Informations collectées', [
      LegalBlock.ul([
        'Identification et contact : nom, prénom, numéro de téléphone et adresse e-mail.',
        'Localisation : position GPS précise pendant l\'utilisation de l\'application. Pour les livreurs, la position est '
            'transmise pendant le service ; sur iPhone, la localisation en arrière-plan n\'est utilisée que pendant une '
            'livraison en cours.',
        'Commandes : adresses de livraison, historique.',
        'Paiement et portefeuille : soldes, transactions et numéros de paiement mobile fournis pour payer. Aucune '
            'donnée de carte bancaire n\'est stockée par AZ Express.',
        'Pièces et photos : pièce d\'identité et selfie demandés aux livreurs et aux propriétaires de flotte ; selfie '
            'd\'acceptation et photo de preuve de livraison ; photo de profil facultative ; photos que vous joignez '
            '(produits, annonces, support).',
        'Communications : messages avec le support et captures d\'écran jointes ; messages vocaux et audio échangés '
            'dans le suivi d\'une commande ou une conversation.',
        'Recherches de lieux : les adresses que vous saisissez pour chercher un lieu ou un itinéraire.',
        'Données techniques : identifiant d\'installation et d\'appareil, jeton de notification.',
        'Mesures d\'usage et rapports de plantage collectés automatiquement (Firebase Analytics et Crashlytics, '
            'Google) pour corriger les erreurs et améliorer l\'application.',
      ]),
    ]),
    LegalSection('3. Utilisation des données', [
      LegalBlock.ul([
        'Traiter et suivre vos commandes en temps réel.',
        'Mettre en relation clients, livreurs et commerçants.',
        'Envoyer des notifications sur vos commandes.',
        'Vérifier l\'identité des livreurs et des propriétaires de flotte.',
        'Améliorer nos services, assurer la sécurité et prévenir la fraude.',
        'Respecter nos obligations légales et vous contacter au sujet de votre compte.',
      ]),
    ]),
    LegalSection('4. Partage des données', [
      LegalBlock.p('Nous ne vendons jamais vos données personnelles. Elles peuvent être partagées avec :'),
      LegalBlock.ul([
        'nos livreurs partenaires (nom et adresse de livraison uniquement) ;',
        'nos commerçants partenaires (commande et coordonnées nécessaires à la livraison) ;',
        'Firebase / Google (hébergement, authentification, notifications, mesures d\'usage et rapports de plantage) ;',
        'Google (Maps, Places, Routes) et OpenStreetMap (Nominatim) : recherche d\'adresses, cartes et itinéraires ;',
        'FeexPay (paiements mobile money, lorsque ce service est activé) ;',
        'Anthropic (États-Unis) et, en secours, Google (Gemini) : fournisseurs d\'intelligence artificielle de '
            'l\'assistant AZ IA, uniquement après votre accord (voir section 9). Aucun autre fournisseur d\'IA n\'est '
            'cité ici ; cette liste sera mise à jour si elle change ;',
        'Apple (iPhone) ou Google (Android) : reconnaissance vocale de la dictée, selon leurs propres conditions ;',
        'les autorités judiciaires, uniquement si la loi l\'exige.',
      ]),
    ]),
    LegalSection('5. Localisation', [
      LegalBlock.p(
          'La localisation sert à trouver les services proches, permettre aux livreurs de vous rejoindre et calculer '
          'prix et délais. Nous vous expliquons son utilité avant la demande d\'autorisation de votre téléphone. Vous '
          'pouvez la refuser ou la désactiver dans les paramètres ; certaines fonctions seront alors limitées.'),
    ]),
    LegalSection('6. Sécurité', [
      LegalBlock.p(
          'Chiffrement en transit (HTTPS/TLS), règles de sécurité Firebase, authentification, accès limité aux données '
          '(moindre privilège) et surveillance des accès anormaux. Aucun système n\'est infaillible : protégez votre '
          'mot de passe.'),
    ]),
    LegalSection('7. Conservation et suppression', [
      LegalBlock.p('Vos données sont conservées tant que votre compte est actif.'),
      ...deletionDelayBlocks,
      LegalBlock.p(deletionBlockedCases),
      LegalBlock.p('**Données supprimées ou anonymisées :**'),
      LegalBlock.ul(deletedData),
      LegalBlock.p('**Informations non supprimées avec le compte (exceptions) :**'),
      LegalBlock.ul(keptData),
      LegalBlock.p('**Durées de conservation :** $durationsNotice'),
    ]),
    LegalSection('8. Vos droits', [
      LegalBlock.p(
          'Vous pouvez accéder à vos données, les corriger, vous opposer à leur traitement, retirer votre '
          'consentement et demander la suppression de votre compte.'),
      LegalBlock.p(
          'Contact : ${LegalContact.email} · WhatsApp ${LegalContact.whatsapp}.'),
      LegalBlock.callout(
          '**Supprimer votre compte :** dans l\'application (Profil, « Supprimer mon compte ») pour les clients et les '
          'livreurs, ou en nous écrivant. Toutes les indications sont sur la page '
          '${LegalContact.deleteAccountDisplay}.'),
    ]),
    LegalSection('9. Assistant AZ IA', [
      LegalBlock.p(
          'AZ IA s\'appuie sur des services d\'intelligence artificielle externes : **Anthropic** (fournisseur '
          'principal) et, uniquement si le premier est indisponible, **Google (Gemini)**. **Rien n\'est envoyé à ces '
          'fournisseurs sans votre accord explicite**, demandé avant votre premier message à AZ IA. Si vous refusez, '
          'AZ IA n\'est pas utilisé et aucune donnée n\'est transmise ; le reste de l\'application fonctionne '
          'normalement. Vous pouvez retirer votre accord à tout moment depuis le menu ⋮ de la conversation.'),
      LegalBlock.p(
          'Toujours transmis : votre message (ou la transcription de votre voix) et le début de la conversation en '
          'cours. Transmis seulement si vous les utilisez ou si votre demande en a besoin : les photos que vous '
          'joignez ; votre nom, numéro de téléphone, adresses et préférences enregistrées ; votre dernière commande, '
          'le suivi d\'une commande, votre solde ou vos mouvements de portefeuille ; votre position GPS si la '
          'localisation est autorisée. Une question générale n\'envoie aucune de ces informations personnelles. '
          'Elles ne sont ni vendues ni utilisées à des fins publicitaires, et servent uniquement à répondre à votre '
          'demande.'),
      LegalBlock.p(
          'Saisie vocale : la dictée utilise la reconnaissance vocale de votre téléphone (Apple sur iPhone, Google sur '
          'Android). L\'audio peut être traité par ce service selon ses propres conditions ; AZ Express et AZ IA ne '
          'reçoivent que le texte transcrit, jamais l\'enregistrement.'),
      LegalBlock.p(
          'Aucune action financière ou destructrice (paiement, retrait, remboursement, suppression) n\'est exécutée '
          'sans votre confirmation explicite. Vous pouvez effacer votre historique de conversation depuis '
          'l\'application. À la suppression de votre compte, l\'historique de conversation, la mémoire, les rappels et '
          'les demandes non confirmées d\'AZ IA sont effacés ; la trace de votre consentement et les opérations que '
          'vous avez confirmées peuvent être conservées (section 7).'),
    ]),
    LegalSection('10. Autorisations et notifications', [
      LegalBlock.p(
          'Avant chaque demande d\'autorisation de votre téléphone, l\'application vous explique à quoi elle sert. '
          'Vous pouvez refuser : l\'application reste utilisable pour tout ce qui n\'en dépend pas.'),
      LegalBlock.ul([
        'Notifications : suivre l\'état de vos commandes, les confirmations de paiement et les alertes de sécurité.',
        'Localisation : trouver les services proches, vous livrer, calculer prix et délais.',
        'Caméra : photographier un produit, une pièce justificative ou une preuve de livraison.',
        'Microphone : messages vocaux et dictée.',
        'Photos et fichiers : joindre une image existante.',
      ]),
      LegalBlock.p('Vous pouvez modifier ces choix à tout moment dans les paramètres de votre appareil.'),
    ]),
    LegalSection('11. Mineurs', [
      LegalBlock.p(
          'Nos services s\'adressent aux personnes de 16 ans et plus. Nous ne collectons pas sciemment de données de '
          'mineurs ; contactez-nous si vous pensez qu\'un mineur utilise nos services.'),
    ]),
    LegalSection('12. Modifications', [
      LegalBlock.p(
          'Nous pouvons modifier cette politique ; les changements importants vous seront notifiés dans '
          'l\'application. La date de mise à jour figure en haut de ce document.'),
    ]),
    LegalSection('13. Contact', [
      LegalBlock.p(
          '${LegalContact.email} · WhatsApp ${LegalContact.whatsapp} · ${LegalContact.place}'),
    ]),
  ];

  /// Page « Suppression de compte » (mêmes listes que la politique).
  static const deletePageTitle = 'Suppression de votre compte AZ Express';
  static const deletePageIntro =
      'Application AZ Express (com.azexpress.app), éditée par AZ Express, Abengourou, Côte d\'Ivoire. Cette page est '
      'publique : aucune connexion n\'est nécessaire pour la consulter.';

  static const deleteSections = <LegalSection>[
    LegalSection('Dans l\'application (clients et livreurs)', [
      LegalBlock.p('1. Ouvrez AZ Express et connectez-vous.'),
      LegalBlock.p('2. Allez dans **Profil**, puis **Supprimer mon compte**.'),
      LegalBlock.p(
          '3. Confirmez votre identité (mot de passe) : votre connexion doit dater de moins de 5 minutes.'),
      LegalBlock.p(
          '4. Votre compte est bloqué dès la demande ; il est supprimé après une courte période de sécurité. Vous '
          'pouvez suivre l\'état de la demande dans l\'application.'),
      LegalBlock.p(deletionBlockedCases),
    ]),
    LegalSection('Depuis ce site, sans l\'application', [
      LegalBlock.p(
          'Écrivez-nous en indiquant le **numéro de téléphone du compte** et son **rôle** (client, livreur, '
          'partenaire, artisan, prestataire d\'événements) :'),
      LegalBlock.ul([
        'par e-mail : ${LegalContact.email}',
        'ou par WhatsApp : ${LegalContact.whatsapp}',
      ]),
      LegalBlock.p(
          'Nous vérifions votre identité avant tout traitement. Votre message ne supprime pas le compte '
          'immédiatement. Les comptes de partenaires (restaurants, boutiques, pharmacies, etc.) sont toujours '
          'examinés par notre équipe avant suppression.'),
    ]),
    LegalSection('Délai', [
      ...deletionDelayBlocks,
    ]),
    LegalSection('Données supprimées ou anonymisées', [
      LegalBlock.ul(deletedData),
    ]),
    LegalSection('Données conservées (exceptions)', [
      LegalBlock.ul(keptData),
      LegalBlock.p('**Durées de conservation :** $durationsNotice'),
    ]),
    LegalSection('Questions', [
      LegalBlock.p('${LegalContact.email} · Politique de confidentialité : /confidentialite'),
    ]),
  ];
}
