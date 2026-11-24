# Rules validation — 26 October 2026

PASS for the targeted rules correction; PARTIEL for the overall QR release. No deployment.

Provenance: supplied release.json references exactly ruleset.json.name, project az-express-b0469, release cloud.firestore, ruleset e72e0374-40ef-4fc1-b629-4c1a6ced4987, updateTime 2026-10-18T00:26:18.273505Z. One source file, firestore.rules. This verifies the supplied export, not that production cannot change after it.

Complete candidate: rules/firestore.qr.rules. Exact diff: rules/qr.patch. Only seven lines are added: comment, three deny matches, blank line, two owner-branch conjuncts. No existing line is removed or replaced. Removing these additions reconstructs the export exactly (tests/rules-preservation.cjs).

QR collections need no client allow: Admin SDK performs operations through secured callables. Deny rules cover registry/token documents and the manager document plus descendants. No preexisting recursive/global allow overlaps these paths. Restaurant ownership is admin-controlled; pharmacy currentUid cannot be self-assigned; pharmacy_owners has no client allow in this export. Seller/bakery ordinary owners can no longer add, modify or remove isActive/isSuspended/isDeleted/status/deletionRequested, because those fields control public QR availability. Legitimate profile edits and existing admin branches remain available.

Commands, payments, wallet rules, driver rules and account_deletion_requests are retained verbatim. This does not import local account-deletion features absent from the active export, or certify all historical rules free of flaws. Existing admin financial authority remains unchanged.

Tests: Node.js 22, Firestore Emulator, demo-partner-qr on 127.0.0.1:8198. Final run 25/25 passed, zero failures. Includes real client SDK permission requests, Admin SDK initialization concurrency, stable identity, manager grant/revocation, identity forgery, read/list/create/update/delete denials, flag addition/change/removal/full replacement, legitimate profile/admin updates, order deletion denials, wallet increases and cross-user edits denied, driver payment mutation denied, historical deletion-request submission preserved. Auth target lookup is mocked in QR service integration; no real Auth/Storage deletion tested or needed here. Initial attempt before emulator startup failed at setup; after emulator ready final complete run passed. No protection was weakened to make tests pass.

Limits: not an exhaustive business regression suite or physical-device test. Owner clients writing the now-protected availability fields will receive permission-denied; verify distributed partner payloads before publication. Runtime configuration, reproducible isolated install, Hosting isolation and browser/mobile validation remain separate release gates. Check the active release again immediately before any future authorized deployment.

Preparation only: from qr-release, after explicit authorization and all gates resolved, the isolated rules command is:

    firebase deploy --project az-express-b0469 --config firebase.json --only firestore:rules

NOT EXECUTED. Do not deploy the fragment. Keep the supplied export, candidate, patch and manifest. Prefer forward repair for regressions; do not restore owner ability to reactivate QR availability while public QR remains active. No rollback may delete QR registries or financial history.
