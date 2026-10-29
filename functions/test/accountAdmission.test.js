'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {assertNewAccountActivity}=require('../accountAdmission');
const {isEligibleAgent}=require('../ekbineFlow');
class HttpsError extends Error{constructor(code,message){super(message);this.code=code;}}
for(const collection of ['clients','restaurants','pharmacies','sellers'])test('admission refuses '+collection+' deletion before financial mutation',async()=>{
 const stored={wallet:400,deletionRequested:true};
 const db={collection:c=>({doc:id=>({path:c+'/'+id})})};
 const tx={get:async ref=>({exists:!ref.path.startsWith('account_tombstones/'),data:()=>ref.path.startsWith(collection+'/')?stored:{wallet:500}})};
 await assert.rejects(assertNewAccountActivity(tx,db,HttpsError,'u',collection==='clients'?[]:[[collection,'p']]),{code:'failed-precondition'});
 assert.equal(stored.wallet,400);
});
test('durable marker blocks admission even when the profile is missing',async()=>{
 const reads=[];
 const db={collection:c=>({doc:id=>({path:c+'/'+id})})};
 const tx={get:async ref=>{reads.push(ref.path);return {exists:ref.path==='account_tombstones/u'};}};
 await assert.rejects(assertNewAccountActivity(tx,db,HttpsError,'u'),{code:'failed-precondition'});
 assert.deepEqual(reads,['account_tombstones/u']);
});
test('normal admission remains possible without a deletion marker',async()=>{
 const db={collection:c=>({doc:id=>({path:c+'/'+id})})};
 const tx={get:async()=>({exists:false})};
 await assertNewAccountActivity(tx,db,HttpsError,'u');
});
test('Ekbine excludes pending deletion without changing old mission data',()=>{
 const agent={isVerified:true,subscriptionStatus:'active',walletBalance:400,deletionRequested:true};
 assert.equal(isEligibleAgent(agent),false);assert.equal(agent.walletBalance,400);
 assert.equal(isEligibleAgent({...agent,deletionRequested:false}),true);
});
