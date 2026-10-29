'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
for(const [key,value] of Object.entries({FIRESTORE_EMULATOR_HOST:'127.0.0.1:8198',FIREBASE_AUTH_EMULATOR_HOST:'127.0.0.1:9198',FIREBASE_STORAGE_EMULATOR_HOST:'127.0.0.1:9298'})) {
  if(process.env[key]!==value)throw Error('This test requires all three local emulators: '+key);
}
const admin=require('../functions/node_modules/firebase-admin');
const {initializeApp,deleteApp}=require('firebase/app');
const {getAuth,connectAuthEmulator,signInWithEmailAndPassword,signOut}=require('firebase/auth');
const {getFirestore,connectFirestoreEmulator,doc,setDoc,updateDoc,terminate}=require('firebase/firestore');
const {buildAccountDeletion,QUIET_MS}=require('../functions/accountDeletion');
const {buildPharmacyOwnerIdentity}=require('../functions/pharmacyOwnerIdentity');
const {erasePersonalAssets,PERSONAL_PREFIXES}=require('../functions/accountPersonalAssets');
const projectId='demo-account-deletion',bucketName=projectId+'.appspot.com';
let backend,db,auth,bucket,now,api;
class HttpsError extends Error{constructor(code,message){super(message);this.code=code;}}
test.before(async()=>{
 backend=admin.initializeApp({projectId,storageBucket:bucketName},'deletion-real');
 db=backend.firestore();auth=backend.auth();bucket=backend.storage().bucket();
 now=Date.now();
 api=buildAccountDeletion({db,auth,admin,HttpsError,clock:()=>now,eraseAssets:async(uid,role)=>{
  await erasePersonalAssets(bucket,uid,role);
 }});
 await db.doc('operations_control/account_deletion').set({enabled:true,inventoryVersion:1});
});
test.after(async()=>{await backend.delete();});
test('pharmacy nomination and consent use permanent real Auth Emulator accounts',async()=>{
 const suffix=Date.now(),ids=['super-'+suffix,'owner-'+suffix],apps=[];
 const tokens=[];
 try{
  for(const uid of ids){
   const email=uid+'@example.test',password='Fictitious-only-492!';
   await auth.createUser({uid,email,password});
   const app=initializeApp({projectId,apiKey:'fake-api-key'},uid);apps.push(app);
   const sdk=getAuth(app);connectAuthEmulator(sdk,'http://127.0.0.1:9198',{disableWarnings:true});
   const user=(await signInWithEmailAndPassword(sdk,email,password)).user;
   tokens.push(await auth.verifyIdToken(await user.getIdToken()));
  }
  now=Date.now();await db.doc('admins/'+ids[0]).set({isActive:true,role:'super'});
  const pharmacyId='pharmacy-'+suffix;
  await db.doc('pharmacies/'+pharmacyId).set({wallet:400,currentUid:'legacy-session'});
  const handler=buildPharmacyOwnerIdentity({db,auth,admin,HttpsError,clock:()=>now});
  await handler({auth:{uid:ids[0],token:tokens[0]},data:{action:'nominate',uid:ids[1],pharmacyId}});
  const own=data=>({auth:{uid:ids[1],token:tokens[1]},data});
  assert.equal((await handler(own({action:'inspect'}))).pharmacyId,pharmacyId);
  assert.equal((await handler(own({action:'accept'}))).linked,true);
  const result=await api.request(own({role:'pharmacie',recoveryToken:'c'.repeat(64)}));
  assert.equal(result.status,'blocked');assert.equal(result.authDeleted,false);
  assert.equal((await auth.getUser(ids[1])).uid,ids[1]);
  assert.equal((await db.doc('pharmacies/'+pharmacyId).get()).data().wallet,400);
 }finally{for(const app of apps)await deleteApp(app);}
});
for(const role of ['client','livreur'])test(role+': real Auth deletion, Storage cleanup, reconnect denied and SDK recreation denied',async()=>{
 const uid='real-'+role+'-'+Date.now(),email=uid+'@example.test',password='Fictitious-only-492!';
 await auth.createUser({uid,email,password});
 const app=initializeApp({projectId,apiKey:'fake-api-key',authDomain:projectId+'.firebaseapp.com'},uid);
 const sdkAuth=getAuth(app);connectAuthEmulator(sdkAuth,'http://127.0.0.1:9198',{disableWarnings:true});
 const sdkDb=getFirestore(app);connectFirestoreEmulator(sdkDb,'127.0.0.1',8198);
 try{
  const signed=await signInWithEmailAndPassword(sdkAuth,email,password);
  const decoded=await auth.verifyIdToken(await signed.user.getIdToken());
  now=Date.now();
  const collection=role==='client'?'clients':'livreurs';
  await db.doc(collection+'/'+uid).set({wallet:0,name:'Fictitious',phone:'TEST',isOnDelivery:false});
  const asset=bucket.file((role==='client'?'client_photos':'driver_selfies')+'/'+uid+'/test.jpg');
  await asset.save(Buffer.from('fictitious image'),{contentType:'image/jpeg'});
  const r=await api.request({auth:{uid,token:decoded},data:{role,recoveryToken:'a'.repeat(64)}});
  assert.equal(r.status,'quarantined');
  await assert.rejects(setDoc(doc(sdkDb,collection,uid),{wallet:0,name:'recreate'}),e=>e.code==='permission-denied');
  now+=QUIET_MS+1;
  const done=await api.process(uid);assert.equal(done.status,'completed');
  await assert.rejects(auth.getUser(uid),e=>e.code==='auth/user-not-found');
  assert.equal((await asset.exists())[0],false);
  assert.equal((await db.doc(collection+'/'+uid).get()).data().wallet,0);
  await signOut(sdkAuth);
  await assert.rejects(signInWithEmailAndPassword(sdkAuth,email,password));
  assert.equal((await api.process(uid)).status,'completed');
 }finally{await terminate(sdkDb);await deleteApp(app);}
});

for(const blocker of ['mission','balance'])test('real driver '+blocker+' preserves Auth and finance, blocks new acceptance and permits collection',async()=>{
 const uid='blocked-'+blocker+'-'+Date.now(),email=uid+'@example.test',password='Fictitious-only-492!';
 await auth.createUser({uid,email,password});
 const app=initializeApp({projectId,apiKey:'fake-api-key'},uid);
 const sdkAuth=getAuth(app);connectAuthEmulator(sdkAuth,'http://127.0.0.1:9198',{disableWarnings:true});
 const sdkDb=getFirestore(app);connectFirestoreEmulator(sdkDb,'127.0.0.1',8198);
 try{
  const signed=await signInWithEmailAndPassword(sdkAuth,email,password);
  const decoded=await auth.verifyIdToken(await signed.user.getIdToken());now=Date.now();
  await db.doc('livreurs/'+uid).set({wallet:blocker==='balance'?400:0,isOnDelivery:blocker==='mission'});
  const order={driverId:uid,clientId:'fictitious-client',budget:500,isPaid:true,paymentMethod:'wallet',status:'accepted'};
  await db.doc('orders/'+uid+'-active').set(order);
  await db.doc('orders/'+uid+'-new').set({...order,status:'assigned'});
  const result=await api.request({auth:{uid,token:decoded},data:{role:'livreur',recoveryToken:'b'.repeat(64)}});
  assert.equal(result.status,'blocked');assert.equal((await auth.getUser(uid)).disabled,false);
  assert.equal((await db.doc('livreurs/'+uid).get()).data().wallet,blocker==='balance'?400:0);
  await assert.rejects(updateDoc(doc(sdkDb,'livreurs',uid),{deletionRequested:false}),e=>e.code==='permission-denied');
  await assert.rejects(updateDoc(doc(sdkDb,'orders',uid+'-new'),{status:'accepted'}),e=>e.code==='permission-denied');
  await updateDoc(doc(sdkDb,'orders',uid+'-active'),{status:'picked_up'});
  await updateDoc(doc(sdkDb,'orders',uid+'-active'),{status:'delivered'});
 }finally{await terminate(sdkDb);await deleteApp(app);}
});

for(const [role,col] of Object.entries({seller:'sellers',restaurant:'restaurant_owners',pharmacie:'pharmacy_owners',boulangerie:'boulangeries',ekbine_agent:'ekbine_agents',real_estate_agent:'real_estate_agents',fleet_owner:'fleet_owners'}))
test(role+': actual Auth deletion with partner scope, shared business and money retained',async()=>{
 const uid='partner-'+role+'-'+Date.now();now=Date.now();
 await auth.createUser({uid,email:uid+'@example.test',password:'Fictitious-only-492!'});
 const app=initializeApp({projectId,apiKey:'fake-api-key'},uid),sdk=getAuth(app);
 connectAuthEmulator(sdk,'http://127.0.0.1:9198',{disableWarnings:true});
 try{
  const signed=await signInWithEmailAndPassword(sdk,uid+'@example.test','Fictitious-only-492!');
  const token=await auth.verifyIdToken(await signed.user.getIdToken());now=Date.now();
  const data={name:'Fictitious Owner',phone:'TEST',wallet:0};
  if(role==='ekbine_agent')data.walletBalance=0;
  let business;
  if(['restaurant','pharmacie'].includes(role)){
   const field=role==='restaurant'?'restaurantId':'pharmacyId';data[field]='business-'+uid;if(role==='pharmacie')data.uid=uid;
   business=db.doc((role==='restaurant'?'restaurants':'pharmacies')+'/'+data[field]);
   await business.set({name:'Shared business',wallet:0,stock:12});
   await db.doc(col+'/other-'+uid).set({[field]:data[field],uid:'other-'+uid});
  }
  await db.doc(col+'/'+uid).set(data);
  const assets=(PERSONAL_PREFIXES[role]||[]).map(prefix=>bucket.file(prefix+'/'+uid+'/test.jpg'));
  for(const asset of assets)await asset.save(Buffer.from('fictitious personal photo'),{contentType:'image/jpeg'});
  // Personal multirole identity, all profiles consent explicitly included.
  if(role==='ekbine_agent')await db.doc('clients/'+uid).set({name:'Client Owner',wallet:0});
  await db.doc('operations_control/account_deletion').set({enabled:true,inventoryVersion:1,partnerInventoryVersion:1});
  const r=await api.request({auth:{uid,token},data:{role,recoveryToken:'d'.repeat(64),allProfilesConsent:true}});
  assert.equal(r.status,'quarantined');now+=QUIET_MS+1;
  assert.equal((await api.process(uid)).status,'completed');
  await assert.rejects(auth.getUser(uid),e=>e.code==='auth/user-not-found');
  const profile=(await db.doc(col+'/'+uid).get()).data();assert.equal(profile.name,undefined);assert.equal(profile.wallet,0);assert.equal(profile.isDeleted,true);
  for(const asset of assets)assert.equal((await asset.exists())[0],false);
  if(business)assert.deepEqual((await business.get()).data(),{name:'Shared business',wallet:0,stock:12});
  if(role==='ekbine_agent'){const client=(await db.doc('clients/'+uid).get()).data();assert.equal(client.isDeleted,true);assert.equal(client.wallet,0);}
  await signOut(sdk);await assert.rejects(signInWithEmailAndPassword(sdk,uid+'@example.test','Fictitious-only-492!'));
 }finally{await deleteApp(app);}
});
