'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm'),path=require('node:path');
const root=path.resolve(__dirname,'..');
function fixture({actor=true,tomb=false,targetTomb=false,disabled=false}={}){
 const records=new Map([['admins/a',{role:actor?'super':'other',isActive:true}],['restaurants/r',{name:'Restaurant'}]]);
 if(tomb)records.set('account_tombstones/a',{});if(targetTomb)records.set('account_tombstones/u',{});
 const ref=p=>({path:p,collection:c=>({doc:id=>ref(p+'/'+c+'/'+id)}),get:async()=>({exists:records.has(p),data:()=>records.get(p)})});
 const db={collection:c=>({doc:id=>ref(c+'/'+id)}),runTransaction:async fn=>{const writes=[];const out=await fn({get:r=>r.get(),set:(r,d)=>writes.push([r.path,d])});for(const [p,d]of writes)records.set(p,d);return out;}};
 let authReads=0,initialized=0;const imports=[];
 class HttpsError extends Error{constructor(code,message){super(message);this.code=code;}}
 const context={exports:{},require:name=>{imports.push(name);if(name==='firebase-functions/v2/https')return{HttpsError,onCall:(options,handler)=>({options,handler})};if(name==='firebase-functions/v2/firestore')return{onDocumentWritten:(options,handler)=>({options,handler})};if(name==='firebase-admin')return{initializeApp:()=>initialized++,firestore:()=>db,auth:()=>({getUser:async uid=>{authReads++;return{uid,disabled,providerData:[{}]};}})};if(name==='./partnerQr')return require('../functions/partnerQr');throw Error('Unexpected dependency '+name);}};
 vm.runInNewContext(fs.readFileSync(path.join(root,'functions/index.js'),'utf8'),context);
 return {endpoints:context.exports,imports,records,authReads:()=>authReads,initialized:()=>initialized};
}
const req={auth:{uid:'a'},data:{uid:'u',kind:'restaurant',establishmentId:'r',active:true}};
test('exactly eight exports and only QR dependencies',()=>{const f=fixture();assert.deepEqual(Object.keys(f.endpoints).sort(),['getPartnerQr','resolvePartnerQr','listPartnerQrEstablishments','setPartnerQrManager','syncPartnerQr_restaurant','syncPartnerQr_seller','syncPartnerQr_pharmacie','syncPartnerQr_boulangerie'].sort());assert.equal(f.initialized(),1);assert.equal(f.imports.length,4);for(const e of Object.values(f.endpoints))assert.equal(e.options.region,'europe-west1');});
test('quarantined actor cannot grant and target Auth is not consulted',async()=>{const f=fixture({tomb:true});await assert.rejects(f.endpoints.setPartnerQrManager.handler(req),{code:'permission-denied',message:'ACCOUNT_DELETION_IN_PROGRESS'});assert.equal(f.authReads(),0);});
test('unauthenticated actor rejected',async()=>{const f=fixture();await assert.rejects(f.endpoints.setPartnerQrManager.handler({data:req.data}),{code:'unauthenticated'});});
test('non-super actor rejected before target lookup',async()=>{const f=fixture({actor:false});await assert.rejects(f.endpoints.setPartnerQrManager.handler(req),{code:'permission-denied'});assert.equal(f.authReads(),0);});
test('target tombstone prevents grant',async()=>{const f=fixture({targetTomb:true});await assert.rejects(f.endpoints.setPartnerQrManager.handler(req),{code:'failed-precondition'});assert.ok(![...f.records.keys()].some(x=>x.startsWith('partner_qr_managers')));});
test('disabled Auth target prevents grant',async()=>{const f=fixture({disabled:true});await assert.rejects(f.endpoints.setPartnerQrManager.handler(req),{code:'failed-precondition'});});
test('authorized repeat grant is stable and changes no establishment data',async()=>{const f=fixture();await f.endpoints.setPartnerQrManager.handler(req);await f.endpoints.setPartnerQrManager.handler(req);assert.equal([...f.records.keys()].filter(x=>x.startsWith('partner_qr_managers')).length,1);assert.deepEqual(f.records.get('restaurants/r'),{name:'Restaurant'});});
test('isolated business module is byte-identical to reviewed workspace module',()=>{assert.equal(fs.readFileSync(path.join(root,'functions/partnerQr.js'),'utf8'),fs.readFileSync(path.join(root,'../functions/partnerQr.js'),'utf8'));});
