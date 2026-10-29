# QR release gate — 25 October 2026

Verdict: BLOQUÉ for isolated deployment. No production write or deployment performed.

## Chrome

Flutter 3.44.5 on Windows starts Chrome and compiles the suite but does not execute the four assertions. Observed HTTP 404 for `/canvaskit/chromium/canvaskit.js` and `.wasm`, although both files exist in the SDK. DevTools reports WebAssembly HTTP failure and failed dynamic import. Supplying exactly those SDK resources through temporary local DevTools interception exposes a second error: `Web test for webpartner_url_strategy_test.dart not found`. This diagnostic is not a passing test run. No SDK or application routing workaround was persisted. Re-run on a verified Linux/macOS Flutter runner or validate a scoped Windows test-runner fix before claiming success.

## Cache

firebase.json now requests revalidation for all paths by default and for unversioned JS/CSS/WASM. Long immutable caching is reserved for filenames containing a hexadecimal content hash of at least 16 characters. Existing download, APK and association-file policies remain. Headers match the incoming URL before rewrites, hence the default also covers `/partenaire/...`.

11 targeted backend/configuration tests passed, zero failed. Hosting emulator returns HTTP 200 for route shells and assetlinks, but did not return custom Cache-Control headers in this Windows run. Header delivery is NOT validated. No rebuild was necessary for this configuration-only change; previous release artifact is unchanged.

Already cached immutable URLs cannot be invalidated retroactively by a new header. A release needs content-versioned bootstrap/application resources, tested with an existing browser cache, or an explicitly validated cache migration. The existing generated service worker is a retirement worker; that alone does not prove recovery from HTTP caches. No blanket browser-data deletion is proposed.

## Rules

Live Rules API read attempted with existing credentials: HTTP 403. No permissions changed and no further access attempt made. Obtain a fresh authorized export of `projects/az-express-b0469/releases/cloud.firestore` and its referenced ruleset. A historical desktop file is not current-production proof.

Historical comparison: `C:/Users/User/Desktop/firestore_rules_production.rules` versus local rules has 68 added and 16 removed lines. QR-only intended changes: deny SDK operations on partner_qr, partner_qr_tokens and partner_qr_managers subdocuments; prevent seller/bakery owners changing isActive/isSuspended/isDeleted/status. Check all overlapping matches against the fresh baseline: a deny does not override another allow. Pharmacy owner bindings consumed by QR must also be server-controlled. Do not deploy the local rules wholesale: they additionally change account tombstones/deletion/admission and delivery-proof transitions.

## Functions and isolation

Eight exports: getPartnerQr, resolvePartnerQr, listPartnerQrEstablishments, setPartnerQrManager, syncPartnerQr_restaurant, syncPartnerQr_seller, syncPartnerQr_pharmacie, syncPartnerQr_boulangerie.

partnerQr.js imports only node:crypto and receives Firestore/Auth/HttpsError. Management/listing check tombstones and existing ownership/bindings; grant checks super-admin and Auth target. Sync uses Admin SDK transactions. Runtime options: europe-west1, maxInstances 2 for get/resolve/list, 1 for grant and four triggers; triggers retry=true. Memory/timeouts/concurrency/service-account production values are not verified here. No secret binding in QR exports.

Current index.js imports payments and account-deletion modules. setPartnerQrManager uses onCall wrapper calling assertAccountEnabled from accountDeletion.js. Isolated entry must preserve that tombstone protection without initializing deletion/payment exports, with tests proving equivalent behavior. Copying index.js is not isolation. No production-safe isolated package was generated while the baseline is unknown.

Hosting publishes the entire current Web application, including account-deletion and other local features. A QR-only backend package does not isolate that Web artifact. A reviewed mobile/Web release baseline or separately scoped public QR site is required; do not silently publish build/web as QR-only.

## Proposed commands — NOT EXECUTED, NOT AUTHORIZED

Only after an isolated, tested `qr-release/firebase.json` is actually created and reviewed (it does not exist now):

```powershell
firebase deploy --project az-express-b0469 --config qr-release/firebase.json --only firestore:rules
firebase deploy --project az-express-b0469 --config qr-release/firebase.json --only functions:getPartnerQr,functions:resolvePartnerQr,functions:listPartnerQrEstablishments,functions:setPartnerQrManager,functions:syncPartnerQr_restaurant,functions:syncPartnerQr_seller,functions:syncPartnerQr_pharmacie,functions:syncPartnerQr_boulangerie
firebase deploy --project az-express-b0469 --config qr-release/firebase.json --only hosting
```

Never run these against the default main-workspace config. Do not use --force or a global functions deploy. Inspect exported endpoints before deployment; require exactly eight and an explicit source allowlist without .env/secrets/payment/deletion implementation. Require isolated rules emulator tests, runtime configuration review, versioned-cache upgrade tests, and physical Android/iPhone validation. Obtain explicit authorization before any deployment.

After authorized publication: verify HTTP headers and association JSON, installed/uninstalled app links, suspended establishment response, unauthorized manager rejection, PNG/native sharing, and unchanged account/payment journeys. Preserve QR registries in any rollback.
