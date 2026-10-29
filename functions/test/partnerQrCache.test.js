const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs');
test('Hosting revalidates unversioned paths and reserves immutable for hashed resources',()=>{
 const h=JSON.parse(fs.readFileSync('firebase.json','utf8')).hosting;
 const cache=x=>x.headers.find(v=>v.key==='Cache-Control')?.value;
 assert.equal(cache(h.headers[0]),'no-cache, max-age=0, must-revalidate');
 assert.equal(h.headers[0].source,'**');
 const js=h.headers.find(x=>x.source==='**/*.@(js|css|wasm)');assert.ok(!cache(js).includes('immutable'));
 const immutable=h.headers.filter(x=>cache(x)?.includes('immutable'));assert.equal(immutable.length,1);
 const r=new RegExp(immutable[0].regex);assert.ok(r.test('/assets/app.0123456789abcdef.js'));assert.ok(!r.test('/main.dart.js'));assert.ok(!r.test('/flutter_bootstrap.js'));
 assert.ok(h.rewrites.some(x=>x.source==='**'&&x.destination==='/index.html'));
});
