# Compilations mobiles avec Firebase

Utiliser le script validé depuis la racine du dépôt. Il conserve les versions
et les signatures existantes. Il ne publie aucun artefact.

Android (Windows, `.env` au format JSON déjà utilisé par ce projet) :

```powershell
py scripts/build_mobile.py apk --check-only
py scripts/build_mobile.py apk
py scripts/build_mobile.py appbundle
```

iOS (macOS, après restauration Firebase et préparation des profils existants) :

```bash
python3 scripts/build_mobile.py ipa --check-only
python3 scripts/build_mobile.py ipa --build-number "$IOS_BUILD_NUMBER" \
  --export-options "$HOME/export_options.plist"
```

`--build-number "$IOS_BUILD_NUMBER"` overrides the iOS build number for this IPA only. Keep
`pubspec.yaml` at `1.0.10+11`: changing its shared build suffix would also
change Android's default build number. The marketing version remains `1.0.10`.

Le script lance `flutter build <cible> --release --dart-define-from-file=<temporaire>`.
Sur iOS, les valeurs proviennent du plist déjà restauré ; aucune nouvelle variable
Codemagic n'est nécessaire. Le fichier temporaire est créé hors du dépôt, avec
permissions restreintes sur macOS, puis supprimé même si Flutter échoue.

Variables Android : `FIREBASE_ANDROID_API_KEY`, `FIREBASE_ANDROID_APP_ID`,
`FIREBASE_MESSAGING_SENDER_ID`, `FIREBASE_PROJECT_ID`, `FIREBASE_STORAGE_BUCKET`.

Variables iOS : `FIREBASE_IOS_API_KEY`, `FIREBASE_IOS_APP_ID`,
`FIREBASE_MESSAGING_SENDER_ID`, `FIREBASE_PROJECT_ID`, `FIREBASE_STORAGE_BUCKET`,
`FIREBASE_IOS_BUNDLE_ID`.

Le contrôle refuse des valeurs vides, une identité incorrecte et un fichier
`firebase_options.dart` dont les variables ne correspondent pas au contrat.
Les valeurs ne sont jamais affichées par le script. Ne pas utiliser de logs
Flutter verbeux pour publier les commandes internes de compilation.

Un appel direct à `flutter build` contourne ce contrôle : utiliser ce script
pour les releases Android et le workflow corrigé pour iOS. Ne pas ajouter les
fichiers Firebase ou `.env` à Git.

Le workflow Codemagic conserve sa publication App Store Connect préexistante :
son lancement doit donc être autorisé séparément. Aucun workflow distant n'est
lancé pendant cette correction.

Avant distribution : tester sur appareils le premier lancement, la connexion,
AZ IA (conversation existante, nouvelle conversation, navigation), App Check,
et la remontée Crashlytics. Les tests locaux ne valident pas les secrets CI,
les certificats, ni le fonctionnement réel de TestFlight.
