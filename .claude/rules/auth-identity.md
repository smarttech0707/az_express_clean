---
paths:
  - lib/services/auth_service.dart
  - lib/services/account_deletion_service.dart
  - lib/screens/**/*login*.dart
  - lib/screens/**/*register*.dart
  - lib/screens/auth/**
  - lib/screens/admin/admin_otp_page.dart
  - lib/main.dart
  - functions/authEvents.js
  - functions/passwordHash.js
  - functions/passwordReset.js
  - functions/adminPartnerAccounts.js
---

# Authentification, sessions, identité — invariants

Références : `docs/claude/INDEX.md` (prompts 12, 24, 69, 70, 128, 131-135), `docs/ACCOUNT_DELETION_*.md`.

- Rôle = collection du document. Clients : Anonymous Auth par défaut (mobile seulement) + email/mot de passe optionnel. Admins : email/mot de passe + 2FA SMS (Firebase Phone Auth) si un téléphone est enregistré.
- **Pharmacie et Artisan n'ont pas de Firebase Auth** (connexion par Cloud Function, mot de passe haché `hashSecret` / `verifySecret`). Leur « session » persistante = identifiant du document dans `SharedPreferences`, jamais un secret.
- Persistance de session : Firebase Auth persiste nativement ; chaque écran de connexion de rôle vérifie `currentUser` dans `initState()` et reprend le tableau de bord. L'admin saute le mot de passe mais **pas la 2FA**. Ne jamais appeler `signOut` automatiquement ; seule la déconnexion volontaire (avec confirmation, `showLogoutConfirmDialog`) efface la session.
- Bypass OTP admin (`admin_login.dart`) : uniquement si `kDebugMode && _kBypassAdminOtpInDebug`. Inactif en release par construction. Ne jamais le rendre inconditionnel.
- Phone Auth : numéros E.164 ivoiriens uniquement (`smsRegionConfig` CI). Play Integrity exige que l'app soit reconnue par le Play Store (statut 18002 sinon) ; les SHA-1/SHA-256 du keystore **release** doivent être enregistrés dans Firebase. L'écran OTP admin a un timer de secours de 25 s pour ne pas rester bloqué.
- `AuthService.toE164()` retire le 0 initial d'un numéro à 10 chiffres : bug connu (voir known-issues).
- Suppression de compte : client = suppression immédiate (ré-authentification) ; autres rôles = demande dans `account_deletion_requests` (formulaire in-app et page web `/delete-account`), traitée par un admin.
- Journalisation d'identité : `logAuthEvent`, `logAdminAuditEvent` (callables) → `audit_logs`.
- `fcmToken` est unique par compte (écrasé par le dernier appareil) ; le rafraîchissement du token est géré.
- Ne pas afficher de mots de passe ni de codes OTP dans les logs ou rapports.
