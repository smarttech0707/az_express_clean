"use strict";
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs');
const {initializeTestEnvironment,assertFails,assertSucceeds}=require('@firebase/rules-unit-testing');
const admin=require('../functions/node_modules/firebase-admin');
const {buildAccountDeletion,assertAccountEnabled,QUIET_MS}=require('../functions/accountDeletion');
const {buildAccountDeletionSupport}=require('../functions/accountDeletionSupport');
const {buildPharmacyOwnerIdentity}=require('../functions/pharmacyOwnerIdentity');
if(!['127.0.0.1:8197','127.0.0.1:8198'].includes(process.env.FIRESTORE_EMULATOR_HOST))throw Error('Local emulator only');
let env,app,db,now,users,calls,api,failDelete,failAssets;
const token='a'.repeat(64);
class HttpsError extends Error{constructor(code,message){super(message);this.code=code;}}
const missing=()=>Object.assign(Error('missing'),{code:'auth/user-not-found'});
const request=(role='client',age=0)=>({auth:{uid:'u',token:{auth_time:now/1000-age,firebase:{sign_in_provider:'password'}}},data:{role,recoveryToken:token}});
const get=async path=>(await db.doc(path).get()).data();
async function seed(role='client',wallet=0){await db.doc((role==='client'?'clients':'livreurs')+'/u').set({wallet,name:'PRIVATE_NAME',phone:'PRIVATE_PHONE',email:'PRIVATE_EMAIL',isOnDelivery:false});}
test.before(async()=>{env=await initializeTestEnvironment({projectId:'demo-account-deletion',firestore:{rules:fs.readFileSync('firestore.rules','utf8')}});app=admin.initializeApp({projectId:'demo-account-deletion'},'delete-test');db=app.firestore();});
test.beforeEach(async()=>{
 await env.clearFirestore();now=Date.now();users=new Map([['u',{uid:'u'}]]);calls=[];failDelete=false;failAssets=false;
 await db.doc('operations_control/account_deletion').set({enabled:true,inventoryVersion:1});
 const auth={
  updateUser:async(uid,patch)=>{if(!users.has(uid))throw missing();users.set(uid,{...users.get(uid),...patch});calls.push('disable');},
  revokeRefreshTokens:async()=>calls.push('revoke'),
  deleteUser:async uid=>{calls.push('delete');if(failDelete)throw Error('transient');if(!users.delete(uid))throw missing();},
  getUser:async uid=>{calls.push('verify');if(!users.has(uid))throw missing();return users.get(uid);}
 };
 api=buildAccountDeletion({db,auth,admin,HttpsError,clock:()=>now,eraseAssets:async()=>{calls.push('assets');if(failAssets)throw Error('storage unavailable');}});
});
test.after(async()=>{await env.cleanup();await app.delete();});
for(const role of ['client','livreur'])test(role+' confirmed deletion anonymizes profile, preserves financial amounts and prevents reconnect',async()=>{
 await seed(role);const field=role==='client'?'clientId':'driverId';
 await db.doc('orders/old').set({[field]:'u',status:'delivered',budget:500,commission:100,clientName:'NAME',driverName:'NAME',clientPhone:'PHONE',driverPhone:'PHONE'});
 const initial=await api.request(request(role));assert.equal(initial.status,'quarantined');assert.equal(users.has('u'),true);
 await api.process('u');assert.equal(calls.includes('delete'),false);now+=QUIET_MS+1;
 const done=await api.process('u');assert.equal(done.status,'completed');assert.equal(done.authDeleted,true);assert.equal(done.profileAnonymized,true);
 assert.equal(users.has('u'),false);const p=await get((role==='client'?'clients':'livreurs')+'/u');assert.equal(p.name,undefined);assert.equal(p.phone,undefined);assert.equal(p.wallet,0);assert.equal(p.isDeleted,true);
 const o=await get('orders/old');assert.equal(o.budget,500);assert.equal(o.commission,100);assert.equal(o[role==='client'?'clientName':'driverName'],undefined);
 assert.deepEqual(calls,['disable','revoke','delete','verify','assets']);
 assert.equal((await api.status({data:{uid:'u',recoveryToken:token}})).status,'completed');
 await assert.rejects(assertAccountEnabled(db,'u',HttpsError),{code:'permission-denied'});
 const client=env.authenticatedContext('u').firestore();await assertFails(client.doc((role==='client'?'clients':'livreurs')+'/u').set({wallet:0,name:'reactivation'}));
});
for(const role of ['client','livreur'])test(role+' nonzero wallet persists request and allows regularization then retry',async()=>{
 await seed(role,400);let result=await api.request(request(role));assert.equal(result.status,'blocked');assert.equal(calls.length,0);
 assert.equal((await get('account_deletions/u')).reviewRequired,true);
 await db.doc((role==='client'?'clients':'livreurs')+'/u').update({wallet:0});result=await api.process('u');assert.equal(result.status,'quarantined');
});
for(const status of ['assigned','accepted','picked_up','unknown'])test('active or unknown order '+status+' blocks deletion',async()=>{
 await seed('livreur');await db.doc('orders/live').set({driverId:'u',status,budget:500});assert.equal((await api.request(request('livreur'))).status,'blocked');assert.equal(users.has('u'),true);assert.equal(calls.length,0);
});
test('stale authentication persists request but cannot delete until reauthenticated',async()=>{
 await seed();let result=await api.request(request('client',600));assert.equal(result.reason,'reauthentication_required');assert.equal((await api.process('u')).status,'pending');
 result=await api.request(request());assert.equal(result.status,'quarantined');
});
test('anonymous and forged role cannot initiate deletion',async()=>{
 await seed();await assert.rejects(api.request({data:{role:'client',recoveryToken:token}}),{code:'unauthenticated'});
 await assert.rejects(api.request(request('livreur')),{code:'permission-denied'});assert.equal(calls.length,0);
});
test('Auth failure never completes, preserves profile and retries',async()=>{
 await seed();await api.request(request());now+=QUIET_MS+1;failDelete=true;let r=await api.process('u');assert.equal(r.status,'cleanup_pending');assert.equal((await get('clients/u')).name,'PRIVATE_NAME');
 failDelete=false;now+=3600001;r=await api.process('u');assert.equal(r.status,'completed');
});
test('storage failure after Auth deletion is pending; retry verifies missing Auth',async()=>{
 await seed();await api.request(request());now+=QUIET_MS+1;failAssets=true;const result=await api.process('u');assert.equal(result.status,'cleanup_pending');assert.equal(users.has('u'),false);
 failAssets=false;now+=3600001;assert.equal((await api.process('u')).status,'completed');
});
test('response loss can be recovered with capability, not guessed UID',async()=>{
 await seed();await api.request(request());now+=QUIET_MS+1;await api.process('u');
 await assert.rejects(api.status({data:{uid:'u',recoveryToken:'b'.repeat(64)}}),{code:'permission-denied'});
 assert.equal((await api.status({data:{uid:'u',recoveryToken:token}})).status,'completed');
});
test('concurrent workers finalize once and completed receipt does not regress',async()=>{
 await seed();await api.request(request());now+=QUIET_MS+1;await Promise.all([api.process('u'),api.process('u')]);
 assert.equal((await get('account_deletions/u')).state,'completed');assert.equal(calls.filter(x=>x==='delete').length,1);
 await api.process('u');assert.equal(calls.filter(x=>x==='delete').length,1);
});
test('late financial change blocks finalization without losing money',async()=>{
 await seed();await api.request(request());await db.doc('clients/u').update({wallet:500});now+=QUIET_MS+1;
 assert.equal((await api.process('u')).status,'blocked');assert.equal(users.has('u'),true);assert.equal((await get('clients/u')).wallet,500);
});
test('rollout disabled keeps truthful pending request and no tombstone',async()=>{
 await seed();await db.doc('operations_control/account_deletion').delete();assert.equal((await api.request(request())).reason,'server_rollout_not_enabled');assert.equal(calls.length,0);
 assert.equal((await db.doc('account_tombstones/u').get()).exists,false);
});
test('technical state cannot be forged by SDK and pending users retain access',async()=>{
 await seed();const client=env.authenticatedContext('u').firestore();await assertSucceeds(client.doc('clients/u').get());
 await assertFails(client.doc('account_deletions/u').set({state:'completed'}));await assertFails(client.doc('account_tombstones/u').set({state:'deleted'}));
 await api.request(request());await assertFails(client.doc('clients/u').get());await assertFails(client.doc('account_tombstones/u').delete());
});

for(const [role,col] of Object.entries({seller:'sellers',restaurant:'restaurant_owners',boulangerie:'boulangeries',ekbine_agent:'ekbine_agents',real_estate_agent:'real_estate_agents',fleet_owner:'fleet_owners'}))
test(role+' persists verified identity but cannot skip the obligations review',async()=>{
 await db.doc(col+'/u').set(role==='restaurant'?{restaurantId:'r'}:{wallet:400});
 if(role==='restaurant')await db.doc('restaurants/r').set({wallet:400});
 const r=await api.request(request(role));assert.equal(r.status,'blocked');assert.equal(r.reason,'role_obligations_review_required');
 assert.equal((await get('account_deletions/u')).profilePath,col+'/u');assert.equal(users.has('u'),true);assert.equal(calls.length,0);
});
test('support pagination, claim and retry preserve financial blockers and record audit',async()=>{
 await seed('client',400);await api.request(request());
 await db.doc('admins/super').set({role:'super',isActive:true});
 const support=buildAccountDeletionSupport({db,admin,HttpsError,clock:()=>now,process:api.process});
 const req=data=>({auth:{uid:'super',token:{firebase:{sign_in_provider:'password'}}},data});
 assert.equal((await support(req({action:'list'}))).items.length,1);
 await support(req({action:'claim',id:'u'}));
 const r=await support(req({action:'retry',id:'u',resolution:'balance_reviewed'}));assert.equal(r.result.status,'blocked');
 assert.equal((await get('clients/u')).wallet,400);assert.equal((await get('account_deletions/u')).supportOwner,'super');
 assert.equal((await db.collection('account_deletions/u/support_events').get()).size,2);
 const sdk=env.authenticatedContext('u').firestore();await assertFails(sdk.doc('account_deletions/u/support_events/forged').set({action:'complete'}));
});

function pharmacyIdentity(){
 return buildPharmacyOwnerIdentity({db,admin,HttpsError,clock:()=>now,auth:{getUser:async uid=>({uid,disabled:false,providerData:[{providerId:'password'}]})}});
}
const ownerRequest=data=>({...request(),data});
const adminRequest=data=>({auth:{uid:'super',token:{auth_time:now/1000,firebase:{sign_in_provider:'password'}}},data});
async function pharmacySeed(){await db.doc('admins/super').set({role:'super',isActive:true});await db.doc('pharmacies/p').set({wallet:400,currentUid:'unrelated-session'});}
test('permanent pharmacy owner requires nomination and personal acceptance; receipt uses binding not currentUid',async()=>{
 await pharmacySeed();const bind=pharmacyIdentity();
 await assert.rejects(bind(ownerRequest({action:'accept'})),{code:'failed-precondition'});
 await bind(adminRequest({action:'nominate',uid:'u',pharmacyId:'p'}));
 assert.equal((await db.doc('pharmacy_owners/u').get()).exists,false);
 await bind(ownerRequest({action:'accept'}));
 assert.equal((await get('pharmacy_owners/u')).pharmacyId,'p');
 assert.equal((await get('pharmacies/p')).wallet,400);
 assert.equal((await get('pharmacies/p')).currentUid,'unrelated-session');
 const result=await api.request(request('pharmacie'));assert.equal(result.status,'blocked');
 assert.equal((await get('account_deletions/u')).businessPath,'pharmacies/p');assert.equal(calls.length,0);
});
test('anonymous, old authentication and non-admin nomination cannot bind pharmacy',async()=>{
 await pharmacySeed();const bind=pharmacyIdentity();
 await assert.rejects(bind(ownerRequest({action:'nominate',uid:'u',pharmacyId:'p'})),{code:'permission-denied'});
 const anonymous=ownerRequest({action:'accept'});anonymous.auth.token.firebase.sign_in_provider='anonymous';
 await assert.rejects(bind(anonymous),{code:'unauthenticated'});
 const old=ownerRequest({action:'accept'});old.auth.token.auth_time-=600;
 await assert.rejects(bind(old),{code:'unauthenticated'});
});
test('pharmacy binding immutable and blocked by deletion receipt; client writes denied',async()=>{
 await pharmacySeed();const bind=pharmacyIdentity();
 await bind(adminRequest({action:'nominate',uid:'u',pharmacyId:'p'}));await bind(ownerRequest({action:'accept'}));
 await db.doc('pharmacies/other').set({wallet:0});
 await assert.rejects(bind(adminRequest({action:'nominate',uid:'u',pharmacyId:'other'})),{code:'failed-precondition'});
 const sdk=env.authenticatedContext('u').firestore();
 await assertFails(sdk.doc('pharmacy_owners/u').set({pharmacyId:'other',uid:'u'}));
 await assertFails(sdk.doc('pharmacy_owner_invitations/u').set({pharmacyId:'other'}));
 await db.doc('account_deletions/u').set({state:'blocked'});
 await assert.rejects(bind(ownerRequest({action:'accept'})),{code:'failed-precondition'});
});
test('two pharmacy owners remain separate and expired invitation cannot be accepted',async()=>{
 await pharmacySeed();const bind=pharmacyIdentity();
 await bind(adminRequest({action:'nominate',uid:'u',pharmacyId:'p'}));await bind(ownerRequest({action:'accept'}));
 await bind(adminRequest({action:'nominate',uid:'second',pharmacyId:'p'}));
 const second=ownerRequest({action:'accept'});second.auth.uid='second';await bind(second);
 assert.equal((await db.collection('pharmacy_owners').where('pharmacyId','==','p').get()).size,2);
 await db.doc('pharmacy_owner_invitations/late').set({pharmacyId:'p',expiresAt:now-1});
 const late=ownerRequest({action:'accept'});late.auth.uid='late';
 await assert.rejects(bind(late),{code:'failed-precondition'});
});

async function enablePartners(){await db.doc('operations_control/account_deletion').set({enabled:true,inventoryVersion:1,partnerInventoryVersion:1});}
function partnerRequest(role){const r=request(role);r.data.allProfilesConsent=true;return r;}
for(const balance of [400,-100])test('partner balance '+balance+' retained and no Auth deletion',async()=>{
 await enablePartners();await db.doc('sellers/u').set({wallet:balance,name:'Person'});
 assert.equal((await api.request(partnerRequest('seller'))).reason,'balance_regularization_required');
 assert.equal((await get('sellers/u')).wallet,balance);assert.equal(calls.length,0);
 assert.equal((await get('sellers/u')).deletionRequested,true);
});
test('partner retry after Auth failure preserves balances and finalizes once',async()=>{
 await enablePartners();await db.doc('boulangeries/u').set({wallet:0,name:'Person'});
 assert.equal((await api.request(partnerRequest('boulangerie'))).status,'quarantined');now+=QUIET_MS+1;
 failDelete=true;assert.equal((await api.process('u')).status,'cleanup_pending');assert.equal((await get('boulangeries/u')).name,'Person');
 failDelete=false;now+=3600001;assert.equal((await api.process('u')).status,'completed');assert.equal((await get('boulangeries/u')).wallet,0);
});
test('fleet responsibility blocks removal without altering driver or debt',async()=>{
 await enablePartners();await db.doc('fleet_owners/u').set({wallet:0});await db.doc('livreurs/worker').set({ownerId:'u',wallet:400,isOnDelivery:true});
 assert.equal((await api.request(partnerRequest('fleet_owner'))).reason,'responsibilities_transfer_required');
 assert.deepEqual(await get('livreurs/worker'),{ownerId:'u',wallet:400,isOnDelivery:true});assert.equal(calls.length,0);
});
test('partner pending request denies new client order but preserves historic order',async()=>{
 await db.doc('sellers/u').set({wallet:400});
 const sdk=env.authenticatedContext('c',{firebase:{sign_in_provider:'password'}}).firestore();
 const order={clientId:'c',budget:500,status:'pending',isPaid:false,paymentMethod:'cash',sellerType:'boutique',sellerId:'u'};
 await assertSucceeds(sdk.doc('orders/before').set(order));
 await enablePartners();await api.request(partnerRequest('seller'));
 await assertFails(sdk.doc('orders/after').set(order));assert.deepEqual(await get('orders/before'),order);
 const owner=env.authenticatedContext('u',{firebase:{sign_in_provider:'password'}}).firestore();
 await assertFails(owner.doc('sellers/u').update({deletionRequested:false}));
});
test('multirole deletion requires explicit all profiles consent',async()=>{
 await enablePartners();await seed();await db.doc('ekbine_agents/u').set({walletBalance:0});
 assert.equal((await api.request(request())).reason,'all_profiles_consent_required');assert.equal(calls.length,0);
 assert.equal((await api.request(partnerRequest('client'))).status,'quarantined');
});
test('partner Storage failure after Auth removal stays pending and retries safely',async()=>{
 await enablePartners();await db.doc('fleet_owners/u').set({wallet:0,name:'Person'});
 await api.request(partnerRequest('fleet_owner'));now+=QUIET_MS+1;failAssets=true;
 assert.equal((await api.process('u')).status,'cleanup_pending');assert.equal(users.has('u'),false);
 assert.equal((await get('fleet_owners/u')).name,'Person');failAssets=false;now+=3600001;
 assert.equal((await api.process('u')).status,'completed');assert.equal((await get('fleet_owners/u')).wallet,0);
});
test('sole restaurant owner freezes new business activity while shared owner preserves establishment',async()=>{
 await enablePartners();await db.doc('restaurant_owners/u').set({restaurantId:'r'});await db.doc('restaurants/r').set({wallet:400,name:'Business'});
 assert.equal((await api.request(partnerRequest('restaurant'))).status,'blocked');
 assert.equal((await get('restaurants/r')).deletionRequested,true);assert.equal((await get('restaurants/r')).wallet,400);
 assert.equal(calls.length,0);
});
