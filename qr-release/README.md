# Current validation ? 26 October 2026

Active export received and coherent: e72e0374-40ef-4fc1-b629-4c1a6ced4987. Full rules candidate: rules/firestore.qr.rules, now referenced by firebase.json. See RULES_VALIDATION.md; the earlier preparation notes below are historical where they mention missing rules. Hosting remains excluded.

# Isolated partner QR candidate — 26 October 2026

Status: PARTIEL, NOT authorized for deployment. This directory is a separate source package inside the workspace; it does not load the workspace functions/index.js. No production operation was performed.

## Backend

functions/index.js exports exactly eight QR endpoints. functions/partnerQr.js is a byte-identical snapshot of the existing QR implementation. Only firebase-admin and firebase-functions are direct external dependencies; node:crypto is built in. Existing region/maxInstances/retry options are preserved, not inferred from production. No secret or environment file is included.

setPartnerQrManager preserves the original pre-handler tombstone read and error, and the unchanged grant handler preserves super-admin authorization, target Auth validation and transactional target tombstone checks. No deletion/payment initialization or mutation is imported. The original pre-handler check is not a new atomic guarantee against a concurrent actor deletion.

15 targeted tests passed under Node.js 22: eight isolation/authorization tests plus seven existing business tests. These use mocks, not production or emulator integration. Verify transaction/rules integration against the final active-rules-derived candidate before release.

## Required owner input

Supply only release.json and ruleset.json produced by EXPORT_ACTIVE_RULES.ps1 from an already authorized session. Do not send credentials/tokens or user documents. The script reads the active release twice to detect a concurrent rules deployment. If denied, stop; do not change IAM for this task. It has been prepared, not executed.

## Rules candidate

rules/qr-only.fragment.rules is deliberately NOT a complete deployable ruleset. firebase.json contains no rules target. Fresh active rules are missing; a production-safe textual diff cannot yet be produced.

Merge only technical-registry denials and seller/bakery owner update restrictions for isActive/isSuspended/isDeleted/status. Review deletionRequested because availability uses it too; retain any existing restrictions. Verify existing pharmacy binding/currentUid integrity, restaurant ownership, admin authority and all overlapping allow paths. Do not broaden client access. Do not include account-deletion or delivery-proof rule changes from the workspace. Test get/list/create/update/delete and field removal as anonymous, owner, other owner and admin; preserve legitimate profile updates and existing order journeys.

## Hosting isolation

No Hosting target or artifact is included. The existing build/web contains unrelated local functionality and is explicitly excluded. Recommended preparation: recover a verified deployed Hosting release into a separate staging directory, preserve every existing route/file, then add a standalone public /partenaire/** page (only resolvePartnerQr), reviewed association JSON and a reviewed download-page link. Use content-hashed JS/CSS names and revalidated HTML/route responses. Avoid including Flutter account/payment screens. Preserve existing association entries rather than overwrite them.

Hosting publishes a whole site release, not a merge of a directory into the live site. Do not publish a small QR-only folder to the existing site: that could remove existing routes/downloads. Without the deployed baseline and verified endpoint/headers integration, no safe Hosting artifact is claimed. A separate Hosting site/domain would require a separate decision and configuration; none is created here.

## Sequence — future authorization required

1. Obtain active rules export; produce minimal diff and run emulator security/regression tests.
2. Complete reproducible dependency install and validate the eight real Firebase exports/options; verify runtime/service-account/ingress expectations without secrets.
3. Prepare a verified Hosting baseline plus isolated public QR addition; validate cache upgrade and Android/iOS associations.
4. Review candidate file hashes, tests and target list. Obtain explicit authorization.
5. Deploy reviewed minimal rules, then only the eight listed endpoints, then reviewed Hosting artifact. Never deploy the main workspace or all functions.

Conditional backend command, NOT EXECUTED (run from this directory only after authorization):

```powershell
firebase deploy --project az-express-b0469 --config firebase.json --only functions:getPartnerQr,functions:resolvePartnerQr,functions:listPartnerQrEstablishments,functions:setPartnerQrManager,functions:syncPartnerQr_restaurant,functions:syncPartnerQr_seller,functions:syncPartnerQr_pharmacie,functions:syncPartnerQr_boulangerie
```

No rules/Hosting command is executable from this configuration until those candidates are actually prepared. Do not use --force or global deploy. Explicitly check no unexpected endpoint deletion is proposed.

## Recovery and validation

Before publication save active rules release, Hosting release, function source hashes and runtime metadata. Revert Hosting only to its saved complete release if necessary. Preserve QR registries/tokens/grants and their deny rules so printed identities stay stable. If newly introduced endpoints must be disabled/deleted, do so only by separately authorized targeted operations; never delete registries or restore broad client access. Do not roll back unrelated payment/account changes. Prefer an isolated forward fix for QR endpoints where rollback would remove protections.

Physical tests still required: Android Play/direct APK, iOS installed/uninstalled links, suspended establishment, management permissions, multi-establishment selection, public privacy, printed QR, PNG/native sharing, existing browser cache. Chrome runner failure from the preceding audit remains open; this task does not claim it fixed.
