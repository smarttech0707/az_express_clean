'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs');
const {initializeTestEnvironment,assertFails}=require('@firebase/rules-unit-testing');
const {doc,getDoc,setDoc,updateDoc,deleteDoc}=require('firebase/firestore');
const admin=require('../functions/node_modules/firebase-admin');
const {buildPartnerQr,keyFor}=require('../functions/partnerQr');
if(process.env.FIRESTORE_EMULATOR_HOST!=='127.0.0.1:8198')throw Error('Local emulator required');
let env,app,db,api;
class HttpsError extends Error{constructor(code,message){super(message);this.code=code;}}
test.before(async()=>{
 env=await initializeTestEnvironment({projectId:'demo-partner-qr',firestore:{rules:fs.readFileSync('firestore.rules','utf8')}});
 await env.clearFirestore(); // Dedicated local test project; repeatable runs only.
 app=admin.initializeApp({projectId:'demo-partner-qr'},'partner-qr');db=app.firestore();api=buildPartnerQr({db,HttpsError,auth:{getUser:async uid=>({uid,disabled:false,providerData:[{providerId:'password'}]})}});
});
test.after(async()=>{await app.delete();await env.cleanup();});
test('concurrent server initializations persist exactly one identity per establishment',async()=>{
 await db.doc('restaurants/r').set({name:'Public',wallet:400});
 await db.doc('restaurant_owners/u').set({restaurantId:'r'});
 await Promise.all([api.sync('restaurant','r'),api.sync('restaurant','r'),api.sync('restaurant','r')]);
 const record=await db.doc('partner_qr/'+keyFor('restaurant','r')).get();assert.ok(record.data().token);
 assert.equal((await db.collection('partner_qr_tokens').get()).size,1);
 assert.equal((await db.doc('restaurants/r').get()).data().wallet,400);
});
for(const uid of [null,'u','admin'])test('technical QR registry denies every client operation: '+uid,async()=>{
 if(uid==='admin')await db.doc('admins/admin').set({isActive:true,role:'super'});
 const sdk=uid?env.authenticatedContext(uid).firestore():env.unauthenticatedContext().firestore();
 for(const collection of ['partner_qr','partner_qr_tokens','partner_qr_managers/u/establishments']){
  const ref=doc(sdk,collection,'test');
  await assertFails(getDoc(ref));await assertFails(setDoc(ref,{token:'injected'}));
  await assertFails(updateDoc(ref,{token:'replacement'}));await assertFails(deleteDoc(ref));
 }
});
test('multiple server grants list distinct establishments; revocation prevents QR access',async()=>{
 await db.doc('admins/super').set({isActive:true,role:'super'});
 for(const id of ['multi-a','multi-b'])await db.doc('restaurants/'+id).set({name:id,wallet:400});
 const change=(id,active)=>api.grant({auth:{uid:'super'},data:{uid:'manager',kind:'restaurant',establishmentId:id,active}});
 await change('multi-a',true);await change('multi-b',true);
 const list=await api.list({auth:{uid:'manager'}});assert.equal(list.establishments.length,2);
 const get=id=>api.manage({auth:{uid:'manager'},data:{kind:'restaurant',establishmentId:id}});
 const a=await get('multi-a'),b=await get('multi-b');assert.notEqual(a.token,b.token);
 await change('multi-a',false);await assert.rejects(get('multi-a'),{code:'permission-denied'});
 assert.equal((await api.list({auth:{uid:'manager'}})).establishments.length,1);
 assert.equal((await get('multi-b')).token,b.token);
 assert.equal((await db.doc('restaurants/multi-a').get()).data().wallet,400);
});
test('non-admin cannot grant itself QR management; deleted manager cannot list',async()=>{
 await assert.rejects(api.grant({auth:{uid:'attacker'},data:{uid:'attacker',kind:'restaurant',establishmentId:'multi-a',active:true}}),{code:'permission-denied'});
 await db.doc('account_tombstones/deleted').set({state:'completed'});
 await assert.rejects(api.list({auth:{uid:'deleted'}}),{code:'permission-denied'});
});
test('unknown, disabled and anonymous Auth targets cannot receive new management rights',async()=>{
 for(const getUser of [async()=>{throw Error('not found');},async uid=>({uid,disabled:true,providerData:[{}]}),async uid=>({uid,disabled:false,providerData:[]})]){
  const guarded=buildPartnerQr({db,HttpsError,auth:{getUser}});
  await assert.rejects(guarded.grant({auth:{uid:'super'},data:{uid:'invalid-target',kind:'restaurant',establishmentId:'multi-a',active:true}}),{code:'failed-precondition'});
 }
 assert.equal((await db.doc('partner_qr_managers/invalid-target/establishments/'+keyFor('restaurant','multi-a')).get()).exists,false);
});
test('partner cannot unsuspend its public QR by editing security flags',async()=>{
 for(const collection of ['sellers','boulangeries']){
  await db.doc(collection+'/u').set({wallet:0,deletionRequested:false,subscriptionStatus:'active',subscriptionExpiresAt:null,vipStatus:null,vipExpiresAt:null,vipStartedAt:null,plan:null,priorityLevel:0,paymentStatus:null,isSuspended:true});
  await assertFails(updateDoc(doc(env.authenticatedContext('u').firestore(),collection,'u'),{isSuspended:false}));
 }
});
