# Final QR package preparation — 26 October 2026

Verdict PARTIEL. No deployment, publication, production mutation or commit.

## Hosting baseline

Read-only Hosting API identifies sites/az-express-b0469/releases/1791977055377000, released 2026-10-14T11:24:15.377Z, version 3c2331e0f6a31a3e. Rechecked unchanged after download. All 70 inventory files recovered and verified against their SHA-256 compressed source hashes. For motorbike.png/version.json the server sent identity encoding: gzip level 9 of downloaded bytes reproduces the expected hash. Decoded hashes are recorded in hosting-audit/verification.json. The public APK also matches published SHA-256 7B60FAB2532080E504701F819F5527CB04DCA8ECD1A668DE99037AC520687986.

hosting/ contains every original file unchanged plus four additions: public QR HTML, content-hashed JS, Android assetlinks.json and Apple association file. Existing baseline had neither association file; no old associations removed. Do not use the workspace build/web.

Existing config headers and rewrite are retained; /partenaire/** precedes the original catchall and serves /qr-public/index.html. QR HTML requests revalidation, hashed JS uses existing immutable policy, associations request application/json and five-minute cache. No existing Flutter JS or payment/account screen is rebuilt. Existing legacy cache issues are preserved, not claimed solved; QR route uses different resource URLs. Public content is allowlisted and rendered with textContent. No proof/financial action exists on this page. Download link uses preserved /telecharger/.

## Actual validations this run

- 18 Node.js 22 backend/isolation/association tests passed, zero failed.
- 25 Firestore Emulator tests passed, zero failed; exact active-rules reconstruction check passed.
- Five Chrome checks passed with callable responses mocked: available/XSS-safe display, unavailable, server error, invalid token without a call, preserved download link. Initial test harness failed to handle CORS OPTIONS; mock corrected; final run passed. These are new static-page browser checks, not the previously failing Flutter Chrome suite.
- Hosting Emulator: /partenaire/token serves QR HTML; / serves original Flutter; /telecharger/ serves original page; associations reachable. However custom Cache-Control headers are absent and Apple file Content-Type is `false` on this Windows emulator. Therefore HTTP header validation is NOT passed. Require verification on a working local Linux/macOS Hosting Emulator before approval, then real HTTPS headers after separately authorized publication.
- 70 candidate source-file decoded hashes match the baseline; rewrite order and content-hashed JS verified.
- No real deployed resolvePartnerQr invocation, physical mobile link test, iOS provisioning check or store binary behavior test performed.

## Partner compatibility evidence

Current sources and historical commit 53a4323 (pubspec 1.0.10+11; commit message mentions TestFlight build 13) were examined, without asserting a binary mapping. b72f138 likewise says build 12 but pubspec remains +11. Public distribution metadata declares Android 1.0.10 (11), and recovered APK bytes match that metadata. No Play/App Store binary-to-source mapping was established.

seller_dashboard.dart:334-343 writes photoUrl with merge/update. boulangerie_dashboard.dart:59-61 writes isOpen; :214-223 writes logoUrl. Notification token uses merge. Seller product editor :730-745 writes boutique_products, not protected seller profile status. Bakery sellerStatus targets orders, not establishment status. Login reads isActive rather than writing it. These inspected payloads do not modify isActive/isSuspended/isDeleted/status/deletionRequested. Full profile replacement removing those fields or old clients writing them will be denied as intended; do not weaken rules. Exact distributed Android/iOS versions and any additional old payloads remain unproven. Preserve existing admin authority.

## Gates and physical tests

Before authorization: validate custom headers on a functioning emulator; confirm isolated dependency npm ci under Node22; compare current function runtime/identity expectations and active rules/version against captured baseline; inspect actual partner test builds. Android: Play-signed and directly signed APK on real device, verify App Links, scan installed/uninstalled, available/suspended QR, photo/isOpen/FCM updates. iOS: confirm team/bundle/provisioning Associated Domains and public App Store availability; scan via Camera/Safari on installed/uninstalled device. No claim older binaries contain the new routes/entitlements. Test calls and grants only on authorized fixtures/staging before real partner activation.

## Proposed commands — NOT EXECUTED

Run only from D:\az_express_clean\qr-release, after explicit approval and gates:

    firebase deploy --project az-express-b0469 --config firebase.json --only firestore:rules
    firebase deploy --project az-express-b0469 --config firebase.json --only functions:getPartnerQr,functions:resolvePartnerQr,functions:listPartnerQrEstablishments,functions:setPartnerQrManager,functions:syncPartnerQr_restaurant,functions:syncPartnerQr_seller,functions:syncPartnerQr_pharmacie,functions:syncPartnerQr_boulangerie
    firebase deploy --project az-express-b0469 --config firebase.json --only hosting

Stop after each stage for permission/functional checks. Never global functions deploy or --force. Before Hosting, confirm the release still equals captured version; otherwise retrieve and merge new changes, not overwrite them.

## Recovery

Record rules release, function revisions/settings and Hosting release immediately before deployment. For a Hosting regression restore the captured full release through an explicitly authorized Hosting rollback; the QR route may be temporarily unavailable, but original site preserved. Preserve QR registries/tokens/grants always. Prefer forward correction for security-rule issues; do not restore owners' ability to bypass suspension while exposing public QR. Target only QR functions for rollback; do not delete endpoints needed by installed clients without an explicit plan. No data deletion, financial restore or account restore is part of rollback.

## Additional executed validation — 26 October 2026

- Autonomous `npm ci --no-audit --no-fund` executed in qr-release/functions with Node 22.23.3 and its directory first in PATH: success, 228 packages. No engine mismatch. npm reports deprecated transitive uuid versions; no dependency upgrade performed. Vulnerability audit was not run.
- With NODE_PATH cleared, all eight exports load from qr-release/functions/node_modules (no workspace SDK fallback). runtime-local.json records SDK metadata: gcfv2, europe-west1; maxInstances 2 for get/resolve/list, 1 for grant/triggers; four Firestore written triggers on the expected collections with retry=true. No configured secret/environment binding. Memory, timeout, concurrency, ingress and service account are unset/null locally, not verified production values.
- Read-only Cloud Functions API with x-goog-user-project: all eight endpoints absent in europe-west1. No existing QR runtime to preserve. Confirm effective defaults/identity and required Firestore/Auth access at future authorized installation; do not claim IAM verified by a local import.
- 11 targeted isolation/association tests re-executed under Node22: all pass, zero fail. Rules unchanged; previous 25-rule-test result not rerun in this step.
- Hosting HTTP check repeated: four URLs return 200, custom Cache-Control absent; Apple association Content-Type remains `false` on this Windows emulator. Stored in http-validation.json. NOT a passing header validation.
- Connected Android device inspected read-only: installed package com.azexpress.app 1.0.10 (11). Package dump search contains no QR host/path; pm get-app-links returns no domain result. No live QR was opened, no app installed or account modified. Current source manifests include the association but older binary support is not established.
- Local iOS Generated.xcconfig says 1.0.9 (10), whereas pubspec says 1.0.10+11. This is generated local metadata, not proof of TestFlight/App Store availability. No local IPA or connected iPhone was validated. Existing AAB filenames mention 1.0.6(7), 1.0.7(8), 1.0.8(9), 1.0.9(10); names alone do not prove artifact contents or store distribution. Human confirmation of the test iOS build is required.

### Exact checks after a separately authorized publication — NOT EXECUTED

Use GET headers, not only HEAD; require HTTP 200 with no redirect on association files, valid JSON, both Android fingerprints, and Apple team/bundle match. Require application/json for both association files, cache public/max-age=300; QR HTML no-cache/max-age=0/must-revalidate; content-hashed JS immutable/max-age=31536000. Check / and /telecharger/ still load and an existing browser cache upgrades to the QR page.

```powershell
$origin = 'https://az-express-b0469.web.app'
curl.exe --silent --show-error --dump-header - --output NUL "$origin/.well-known/assetlinks.json"
curl.exe --silent --show-error --dump-header - --output NUL "$origin/.well-known/apple-app-site-association"
$qrUrl = Read-Host 'Paste an existing authorized partner QR URL'
curl.exe --silent --show-error --dump-header - --output NUL "$qrUrl"
curl.exe --silent --show-error --dump-header - --output NUL "$origin/qr-public/partner.7a75a2746918585ac31c0e3d8c8b298a034ec595e44e7ec5ad92d3698e1c8e22.js"
```

### Android device commands — proposed, not executed except read-only version listing

Use a test device with the approved new build and an existing authorized QR URL. These commands request OS verification/open a link; they are not production deployment commands. Do not force-set verified domains, clear app data or override link ownership to hide a failure.

```powershell
$adb = "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe"
& $adb devices -l
& $adb shell dumpsys package com.azexpress.app | Select-String 'versionName=|versionCode='
& $adb shell pm verify-app-links --re-verify com.azexpress.app
# Wait for network verification, then require az-express-b0469.web.app: verified.
& $adb shell pm get-app-links com.azexpress.app
$qrUrl = Read-Host 'Paste an existing authorized partner QR URL'
& $adb shell am start -W -a android.intent.action.VIEW -c android.intent.category.BROWSABLE -d "$qrUrl"
```

Do not pass -p com.azexpress.app: it would bypass normal implicit link resolution. Test Play-signed and direct-APK channels separately; on a separate device without AZ Express confirm the public Web fallback. Verify partner logo/photo/isOpen/FCM updates and blocked security fields on test fixtures, not real partner mutations without approval.

### iPhone

On a Mac, simulator routing can be exercised with:

```sh
read -r QR_URL
xcrun simctl openurl booted "$QR_URL"
```

This is a simulator command, NOT proof of physical Universal Links. Physical test: install the identified approved TestFlight build with correct Associated Domains entitlement, send the existing QR link to Notes/Messages and tap it or scan the printed QR with Camera; verify AZ Express opens the right public establishment. Typing a URL into Safari is not a reliable Universal Link association test. Test Web fallback on a separate device without the app, and unavailable establishment using an authorized test fixture. No iPhone physical test was executed here.

Verdict remains PARTIEL. Human gates: approved mobile test builds/devices and actual association tests; effective new runtime/identity approval; real HTTPS headers after authorized publication (or reliable non-Windows emulator validation first). No deployment authorization is implied.

## Runtime and Android build follow-up

See RUNTIME_ANDROID_CHECK.md for executed read-only IAM/API commands and exact APK inspection results. Compute default exists/enabled, current caller actAs confirmed, relevant Firestore/Auth permissions present in existing Editor role; no live QR invocation or IAM mutation. Android installed 1.0.10(11) resolves no requested QR intent. New signed test APK 1.0.10-qrtest(11) successfully built and inspected, stored outside Hosting in android-test/. Not installed or published. Its manifest has the QR HTTPS filter and direct-distribution certificate matches assetlinks. Human authorization/test-device choice needed before installation; effective OS verification still requires separately approved backend/Hosting publication. Current-workspace APK includes other existing local corrections and is not a QR-only mobile release.
