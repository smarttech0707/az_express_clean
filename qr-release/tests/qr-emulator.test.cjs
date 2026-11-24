'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs');
const {initializeTestEnvironment,assertFails}=require('@firebase/rules-unit-testing');
const {doc,getDoc,setDoc,updateDoc,deleteDoc}=require('firebase/firestore');
const admin=require('../../functions/node_modules/firebase-admin');
const {buildPartnerQr,keyFor}=require('../functions/partnerQr');
if(process.env.FIRESTORE_EMULATOR_HOST!=='127.0.0.1:8198')throw Error('Local emulator required');
let env,app,db,api;
class HttpsError extends Error{constructor(code,message){super(message);this.code=code;}}
test.before(async()=>{
 env=await initializeTestEnvironment({projectId:'demo-partner-qr',firestore:{rules:fs.readFileSync('qr-release/rules/firestore.qr.rules','utf8')}});
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
for(const collection of ['sellers','boulangeries']) {
 for(const field of ['isActive','isSuspended','isDeleted','status','deletionRequested']) {
  test(collection+' owner cannot add/change/remove '+field,async()=>{
   const {deleteField}=require('firebase/firestore');
   const uid='guard-'+collection+'-'+field;
   const ref=db.doc(collection+'/'+uid);await ref.set({name:'Original',wallet:400});
   const sdkRef=doc(env.authenticatedContext(uid).firestore(),collection,uid);
   await assertFails(updateDoc(sdkRef,{[field]:true}));
   await ref.update({[field]:true});await assertFails(updateDoc(sdkRef,{[field]:false}));
   await assertFails(updateDoc(sdkRef,{[field]:deleteField()}));
   await assertFails(setDoc(sdkRef,{name:'Replacement',wallet:400}));
  });
 }
 test(collection+' legitimate profile updates and admin suspension preserved',async()=>{
  const {assertSucceeds}=require('@firebase/rules-unit-testing');
  await db.doc(collection+'/legit').set({name:'Before',wallet:400,isSuspended:false});
  const owner=doc(env.authenticatedContext('legit').firestore(),collection,'legit');
  await assertSucceeds(updateDoc(owner,{name:'After'}));await assertFails(updateDoc(owner,{wallet:999}));
  await db.doc('admins/super-valid').set({role:'super',isActive:true});
  await assertSucceeds(updateDoc(doc(env.authenticatedContext('super-valid',{firebase:{sign_in_provider:'password'}}).firestore(),collection,'legit'),{isSuspended:true}));
 });
}
test('QR denied list, nested grants and identity forgery',async()=>{
 const {collection,getDocs}=require('firebase/firestore');const sdk=env.authenticatedContext('attacker').firestore();
 for(const c of ['partner_qr','partner_qr_tokens','partner_qr_managers/attacker/establishments'])await assertFails(getDocs(collection(sdk,c)));
 for(const p of ['partner_qr_managers/attacker/establishments/x','pharmacy_owners/attacker','restaurant_owners/attacker','account_tombstones/attacker'])await assertFails(setDoc(doc(sdk,p),{uid:'attacker',restaurantId:'r',pharmacyId:'p'}));
 await db.doc('pharmacies/p').set({currentUid:'legitimate',wallet:400});await assertFails(updateDoc(doc(sdk,'pharmacies/p'),{currentUid:'attacker'}));
});
test('orders cannot be deleted by client driver or admin',async()=>{
 await db.doc('orders/protected').set({clientId:'client',driverId:'driver',status:'delivered',budget:1000,isPaid:true});
 for(const uid of ['client','driver','super-valid'])await assertFails(deleteDoc(doc(env.authenticatedContext(uid,{firebase:{sign_in_provider:'password'}}).firestore(),'orders/protected')));
});
test('client and driver cannot increase wallet or change another profile',async()=>{
 for(const c of ['clients','livreurs']){
  await db.doc(c+'/financial').set({wallet:400,fakeOrderCount:0,cashOnDeliveryEnabled:true,isSuspended:false});
  await assertFails(updateDoc(doc(env.authenticatedContext('financial').firestore(),c,'financial'),{wallet:999}));
  await assertFails(updateDoc(doc(env.authenticatedContext('other').firestore(),c,'financial'),{wallet:0}));
 }
});
test('assigned driver cannot change paid state or amount',async()=>{
 await db.doc('orders/financial').set({clientId:'client',driverId:'driver',status:'assigned',budget:1000,isPaid:false,paymentMethod:'cash'});
 const ref=doc(env.authenticatedContext('driver').firestore(),'orders/financial');
 await assertFails(updateDoc(ref,{budget:1}));await assertFails(updateDoc(ref,{isPaid:true}));
});
test('existing account deletion request submission preserved without new read access',async()=>{
 const {assertSucceeds}=require('@firebase/rules-unit-testing');const ref=doc(env.authenticatedContext('client').firestore(),'account_deletion_requests/test');
 await assertSucceeds(setDoc(ref,{role:'client',contactPhone:'0000000000',status:'pending',requestedVia:'app'}));
 await assertFails(getDoc(ref));await assertFails(updateDoc(ref,{status:'completed'}));await assertFails(deleteDoc(ref));
});
