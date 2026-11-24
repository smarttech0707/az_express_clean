# Runtime and installed Android checks — 26 October 2026

Read-only cloud commands actually executed (Bearer token held only in memory; x-goog-user-project: az-express-b0469):

1. GET https://cloudresourcemanager.googleapis.com/v1/projects/az-express-b0469
2. GET https://iam.googleapis.com/v1/projects/az-express-b0469/serviceAccounts/697217052961-compute@developer.gserviceaccount.com
3. POST https://cloudresourcemanager.googleapis.com/v1/projects/az-express-b0469:getIamPolicy with body {} (read-only)
4. GET https://iam.googleapis.com/v1/roles/editor
5. POST https://iam.googleapis.com/v1/projects/az-express-b0469/serviceAccounts/697217052961-compute@developer.gserviceaccount.com:testIamPermissions with body {"permissions":["iam.serviceAccounts.actAs"]} (read-only)

Results: Compute default account exists, disabled=false. Project bindings include roles/editor, roles/eventarc.eventReceiver and roles/run.invoker, without conditions in returned bindings. Editor includes datastore.entities.get/list/create/update and firebaseauth.users.get. Current caller testIamPermissions returns actAs. This does not evaluate all inherited deny policies, cross-service deployment requirements, build service identity or actual function invocation. No writes were used to test permission. No roles changed. Broad Editor permission remains a least-privilege review item before approval.

Eight new QR endpoints are not yet deployed. Local metadata is Gen2, Node22, europe-west1, maxInstances=2 get/resolve/list, 1 manager/triggers, trigger retry=true. serviceAccountEmail/memory/timeout/concurrency are unset locally. Installed firebase-tools backend.js constants are DEFAULT_MEMORY=256, DEFAULT_TIMEOUT_SECONDS=60, DEFAULT_CONCURRENCY=80, with concurrency CPU-dependent. These constants are not observed deployed settings. The checked Compute default is the expected candidate, not an already bound QR function identity. Confirm final serviceConfig after any separately authorized deployment.

Android commands actually executed:

```powershell
$adb = "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe"
& $adb shell pm path com.azexpress.app
& $adb shell cmd package query-activities --brief -a android.intent.action.VIEW -c android.intent.category.BROWSABLE -d https://az-express-b0469.web.app/partenaire/abcdefghijklmnopqrst -p com.azexpress.app
& $adb shell dumpsys package com.azexpress.app | Select-String 'versionCode=|versionName=|autoVerify|az-express-b0469|partenaire'
```

Results: installed base.apk located; versionName=1.0.10, versionCode=11. Intent query: `No activities found`. Thus installed package does not resolve the requested QR HTTPS URL under this query. Local AndroidManifest.xml lines 148-153 contains autoVerify HTTPS host/path. A fresh build is required to test this local filter. No app launch, install, uninstall, data clearing or domain-state override performed.

Build command requested locally:

```powershell
C:\flutter\bin\flutter.bat build apk --release --no-pub --dart-define-from-file=.env --build-name=1.0.10-qrtest --build-number=11
```

This is a test artifact of the current Flutter workspace, not an isolated QR-only mobile release. It includes existing local account/deletion and other changes without editing them. Do not install it over a real-use phone or exercise its production operations without separate approval. Hosting association publication and QR function deployment are still absent; a compiled filter alone cannot prove verified App Links or successful public resolution.

## Build result

Command completed successfully: assembleRelease 605.6 seconds, APK approximately 94.3 MB. Copied to android-test/AZExpress-1.0.10-qrtest-11.apk, outside hosting/ and functions/; not installed/published.

Executed inspection:

```powershell
$aapt = "$env:LOCALAPPDATA\Android\Sdk\build-tools\36.1.0\aapt.exe"
$signer = "$env:LOCALAPPDATA\Android\Sdk\build-tools\36.1.0\apksigner.bat"
$apk = 'build/app/outputs/flutter-apk/app-release.apk'
& $aapt dump badging $apk
& $aapt dump xmltree $apk AndroidManifest.xml
& $signer verify --print-certs $apk
Get-FileHash $apk -Algorithm SHA256
```

Result: com.azexpress.app, versionName 1.0.10-qrtest, versionCode 11, minSdk24, targetSdk36. Packaged manifest confirms flutter_deeplinking_enabled=true, autoVerify=true, HTTPS az-express-b0469.web.app, pathPrefix /partenaire/. Signature verified; certificate SHA256 950EF85E42C78E1C37E39390F4D0F78DBB97D2CF60124C7D20A85101419F1AC9 matches direct-distribution association. APK SHA256 5650DBD52130B0428FA6B6A4B3A561FF4FC27F418163C85914B1A4455FE29670.

Human action next: choose/authorize a test-device installation of this current-workspace build. Do not uninstall a real-use application or clear data to overcome a signature mismatch (Play installations may have the other certificate). No install executed. Verified OS domain association and successful QR lookup remain unavailable until separately authorized Hosting/functions publication; no production change is requested as part of this report. IAM remains untouched; before approval decide whether the broad existing Editor account is acceptable or a separately scoped identity should be used. No runtime service account was explicitly pinned or changed.
