'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {ROLE_COLLECTIONS,readDeletionIdentity}=require('../accountDeletionIdentity');
const {buildAccountDeletionSupport}=require('../accountDeletionSupport');
const {HttpsError}=require('firebase-functions/v2/https');
function fixture(seed={}){
 const store=new Map(Object.entries(seed));let counter=0;
 const ref=path=>({path,id:path.split('/').pop(),collection:name=>col(path+'/'+name),get:async()=>snap(path)});
 const snap=path=>({exists:store.has(path),data:()=>store.get(path),ref:ref(path)});
 const col=path=>({doc:id=>ref(path+'/'+(id||'event'+(++counter)))});
 const tx={get:async r=>snap(r.path),update:(r,p)=>store.set(r.path,{...store.get(r.path),...p}),create:(r,p)=>{assert.equal(store.has(r.path),false);store.set(r.path,p);}};
 const db={collection:col,runTransaction:fn=>fn(tx)};
 return {store,db,tx};
}
for(const [role,collection] of Object.entries(ROLE_COLLECTIONS))test('identity '+role+' does not trust a caller selected profile',async()=>{
 const seed={[collection+'/u']:{},[collection+'/victim']:{}};
 if(role==='restaurant'){seed[collection+'/u']={restaurantId:'business'};seed['restaurants/business']={};}
 if(role==='pharmacie')seed[collection+'/u']={currentUid:'u'};
 const {db,tx}=fixture(seed);
 const identity=await readDeletionIdentity(tx,db,'u',role);
 if(role==='pharmacie')assert.equal(identity,null);
 else assert.equal(identity.profilePath,collection+'/u');
 assert.equal(await readDeletionIdentity(tx,db,'missing',role),null);
});
test('restaurant malformed business link denied',async()=>{
 const {db,tx}=fixture({'restaurant_owners/u':{restaurantId:'other/path'}});
 assert.equal(await readDeletionIdentity(tx,db,'u','restaurant'),null);
});
function supportFixture(adminData={role:'super',isActive:true}){
 const f=fixture({'admins/admin':adminData,'account_deletions/u':{state:'blocked',consentVerified:false,reason:'balance_regularization_required'}});
 const calls=[];
 const api=buildAccountDeletionSupport({db:f.db,HttpsError,clock:()=>1000,admin:{firestore:{FieldValue:{serverTimestamp:()=>123}}},process:async uid=>{calls.push(uid);return {status:'blocked'};}});
 const request=data=>({auth:{uid:'admin',token:{firebase:{sign_in_provider:'password'}}},data});
 return {...f,api,calls,request};
}
test('support retry is audited and cannot override consent, balance or completion',async()=>{
 const {api,request,store,calls}=supportFixture();
 const r=await api(request({action:'retry',id:'u',resolution:'balance_reviewed',consentVerified:true,state:'completed',wallet:0}));
 assert.equal(r.result.status,'blocked');assert.deepEqual(calls,['u']);
 const j=store.get('account_deletions/u');assert.equal(j.consentVerified,false);assert.equal(j.state,'blocked');assert.equal(j.wallet,undefined);
 assert.equal(j.supportOwner,'admin');assert.equal(store.has('account_deletions/u/support_events/event1'),true);
});
test('support rejects subadmin and inactive admin',async()=>{
 for(const value of [{role:'sub',isActive:true},{role:'super',isActive:false}]){
  const {api,request,calls}=supportFixture(value);await assert.rejects(api(request({action:'claim',id:'u'})),{code:'permission-denied'});assert.equal(calls.length,0);
 }
});
test('support cannot turn an unverified manual request into deletion',async()=>{
 const {api,request,calls}=supportFixture();
 await assert.rejects(api(request({action:'retry',kind:'manual',id:'u',resolution:'identity_reviewed'})),{code:'invalid-argument'});
 assert.equal(calls.length,0);
});
test('support cannot mark completed or target a nested path',async()=>{
 const {api,request}=supportFixture();
 await assert.rejects(api(request({action:'complete',id:'u'})),{code:'invalid-argument'});
 await assert.rejects(api(request({action:'claim',id:'u/x'})),{code:'invalid-argument'});
});
