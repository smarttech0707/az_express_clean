'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {buildPartnerQr,keyFor,publicView}=require('../partnerQr');
class HttpsError extends Error{constructor(code,message){super(message);this.code=code;}}
function fixture(extra={}){
 const store=new Map(Object.entries({'restaurants/r':{name:'Restaurant',wallet:400},'restaurant_owners/u':{restaurantId:'r'},...extra}));
 const ref=path=>({path,collection:c=>({doc:id=>ref(path+'/'+c+'/'+id)}),get:async()=>({exists:store.has(path),data:()=>store.get(path)})});
 const db={collection:c=>({doc:id=>ref(c+'/'+id)}),runTransaction:async fn=>{
  const writes=[];const result=await fn({get:r=>r.get(),create:(r,d)=>writes.push([r.path,d])});
  for(const [p] of writes)if(store.has(p))throw Error('already exists');
  for(const [p,d] of writes)store.set(p,d);return result;
 }};
 let ids=0;return {store,api:buildPartnerQr({db,HttpsError,newId:()=>`token-permanent-0000000${++ids}`})};
}
const req=(kind='restaurant',id='r',uid='u')=>({auth:{uid},data:{kind,establishmentId:id}});
test('approval creates stable QR, repeated validation and new phone preserve it',async()=>{
 const {api,store}=fixture();await api.sync('restaurant','r');
 const first=await api.manage(req());await api.sync('restaurant','r');
 store.get('restaurants/r').phone='new';assert.deepEqual(await api.manage(req()),first);
 assert.equal(store.get('restaurants/r').wallet,400);
 assert.equal([...store.keys()].filter(p=>p.startsWith('partner_qr/')).length,1);
});
test('unauthorized user and unauthenticated requests cannot obtain management QR',async()=>{
 const {api}=fixture();await assert.rejects(api.manage(req('restaurant','r','other')),{code:'permission-denied'});
 await assert.rejects(api.manage({data:req().data}),{code:'unauthenticated'});
});
test('public view never exposes sensitive fields and resolves current suspension/deletion',async()=>{
 const {api,store}=fixture();const result=await api.manage(req());
 assert.deepEqual(await api.resolve({data:{token:result.token}}),{available:true,kind:'restaurant',name:'Restaurant'});
 store.get('restaurants/r').isSuspended=true;
 assert.deepEqual(await api.resolve({data:{token:result.token}}),{available:false});
 store.delete('restaurants/r');assert.deepEqual(await api.resolve({data:{token:result.token}}),{available:false});
 assert.deepEqual(publicView('seller',{name:'Shop',wallet:100,phone:'secret',password:'secret'}),{kind:'seller',name:'Shop'});
});
test('different establishments and types never reuse the same mapping',()=>{
 assert.notEqual(keyFor('restaurant','a'),keyFor('restaurant','b'));
 assert.notEqual(keyFor('seller','a'),keyFor('restaurant','a'));
});
test('old approved partner initializes lazily without touching financial data',async()=>{
 const {api,store}=fixture({'sellers/s':{name:'Shop',wallet:450}});
 await api.manage(req('seller','s','s'));assert.deepEqual(store.get('sellers/s'),{name:'Shop',wallet:450});
});
test('pending or deleted establishments and deleted callers remain blocked',async()=>{
 for(const flags of [{status:'pending'},{isDeleted:true},{deletionRequested:true},{isActive:false}]){
 const {api}=fixture({'restaurants/r':{name:'R',...flags}});
 await assert.rejects(api.manage(req()),{code:'failed-precondition'});
 }
 const {api}=fixture({'account_tombstones/u':{state:'deleting'}});
 await assert.rejects(api.manage(req()),{code:'permission-denied'});
});
test('pharmacy authorization accepts only server binding or current server session',async()=>{
 const {api}=fixture({'pharmacies/p':{name:'P'},'pharmacy_owners/u':{uid:'u',pharmacyId:'p'}});
 await api.manage(req('pharmacie','p'));await assert.rejects(api.manage(req('pharmacie','p','other')),{code:'permission-denied'});
});
