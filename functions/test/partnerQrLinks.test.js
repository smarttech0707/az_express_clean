'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const root=path.resolve(__dirname,'../..');
const read=p=>fs.readFileSync(path.join(root,p),'utf8');
test('Android association uses the documented distributed APK certificate and package',()=>{
 const release=JSON.parse(read('web/distribution/latest.json'));
 const links=JSON.parse(read('web/.well-known/assetlinks.json'));
 assert.equal(links[0].target.package_name,release.packageId);
 const fingerprints=links[0].target.sha256_cert_fingerprints;
 assert.ok(fingerprints.some(f=>f.replaceAll(':','')===release.apkCertificateSha256));
 // Play App signing certificate confirmed by the project owner, 25 Oct 2026.
 assert.ok(fingerprints.includes('59:68:92:20:D7:3C:67:B9:5C:67:91:00:BF:D9:A0:F5:8E:49:A2:1E:15:03:DC:76:94:72:B4:C2:A3:9D:E6:99'));
 assert.equal(new Set(fingerprints).size,fingerprints.length);
 for(const fingerprint of fingerprints)assert.match(fingerprint,/^(?:[0-9A-F]{2}:){31}[0-9A-F]{2}$/);
 assert.deepEqual(links[0].relation,['delegate_permission/common.handle_all_urls']);
 assert.equal(links[0].target.namespace,'android_app');
 const manifest=read('android/app/src/main/AndroidManifest.xml');
 assert.match(manifest,/android:autoVerify="true"/);assert.match(manifest,/android:host="az-express-b0469.web.app" android:pathPrefix="\/partenaire\/"/);
});
test('iOS association matches local Xcode identity and partner-only paths',()=>{
 const aasa=JSON.parse(read('web/.well-known/apple-app-site-association'));
 const project=read('ios/Runner.xcodeproj/project.pbxproj');
 assert.match(project,/DEVELOPMENT_TEAM = F6XWK2W7XG;/);assert.match(project,/PRODUCT_BUNDLE_IDENTIFIER = com.azexpress.app;/);
 assert.deepEqual(aasa.applinks.details,[{appID:'F6XWK2W7XG.com.azexpress.app',paths:['/partenaire/*']}]);
 assert.match(read('ios/Runner/Runner.entitlements'),/applinks:az-express-b0469.web.app/);
});
test('Hosting serves association JSON without the old hidden-file exclusion',()=>{
 const hosting=JSON.parse(read('firebase.json')).hosting;
 assert.equal(hosting.public,'build/web');assert.ok(!hosting.ignore.includes('**/.*'));
 assert.ok(hosting.headers.some(h=>h.source==='/.well-known/**'&&h.headers.some(v=>v.key==='Content-Type'&&v.value==='application/json')));
});
