'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {buildPartnerQr,keyFor,publicView}=require('../partnerQr');
const {requireSuperAdmin}=require('../adminGuards');
class HttpsError extends Error{constructor(code,message){super(message);this.code=code;}}
function fixture({auth,...extra}={}){
 const store=new Map(Object.entries({'restaurants/r':{name:'Restaurant',wallet:400},'restaurant_owners/u':{restaurantId:'r'},...extra}));
 const ref=path=>({path,collection:c=>({doc:id=>ref(path+'/'+c+'/'+id)}),get:async()=>({exists:store.has(path),data:()=>store.get(path)})});
 const db={collection:c=>({doc:id=>ref(c+'/'+id)}),runTransaction:async fn=>{
  const writes=[];const result=await fn({
   get:r=>r.get(),
   create:(r,d)=>writes.push([r.path,d,'create']),
   set:(r,d)=>writes.push([r.path,d,'set']),
  });
  for(const [p,,type] of writes)if(type==='create'&&store.has(p))throw Error('already exists');
  for(const [p,d] of writes)store.set(p,d);return result;
 }};
 // Doubles fidèles aux contrats réels (`adminGuards.js`, `index.js`), pas de
 // nouveau mécanisme : `requireSuperAdmin` est la fonction réelle (elle ne lit
 // que `admins/{uid}` via `db.get()`, déjà fourni par ce fixture) ;
 // `checkRateLimit` reproduit l'algorithme de fenêtre glissante de `index.js`
 // en mémoire ; `logAudit` capture les appels pour assertion.
 const rateLimitHits=new Map();
 const auditLog=[];
 const checkRateLimit=async(uid,action,maxRequests,windowSeconds)=>{
  const now=Date.now(),windowStart=now-windowSeconds*1000;
  const key=`${uid}_${action}`;
  const recent=(rateLimitHits.get(key)||[]).filter(t=>t>windowStart);
  if(recent.length>=maxRequests)throw new HttpsError('resource-exhausted','Trop de tentatives. Veuillez réessayer plus tard.');
  recent.push(now);rateLimitHits.set(key,recent);
 };
 const logAudit=async details=>{auditLog.push(details);};
 let ids=0;
 return {
  store,auditLog,rateLimitHits,
  api:buildPartnerQr({
   db,HttpsError,newId:()=>`token-permanent-0000000${++ids}`,
   requireSuperAdmin,checkRateLimit,logAudit,
   auth,
  }),
 };
}
const req=(kind='restaurant',id='r',uid='u')=>({auth:{uid},data:{kind,establishmentId:id}});
const grantReq=(overrides={})=>({auth:{uid:'boss'},data:{uid:'beneficiary',kind:'restaurant',establishmentId:'r',active:true,...overrides}});
const fakeAuth=(users={})=>({getUser:async uid=>{
 if(!Object.hasOwn(users,uid))throw new Error('Firebase: no user record');
 return users[uid];
}});
function grantFixture(extra={}){
 return fixture({
  auth:fakeAuth({beneficiary:{uid:'beneficiary',disabled:false,providerData:[{providerId:'password'}]}}),
  'admins/boss':{role:'super',isActive:true},
  'admins/subby':{role:'sub',isActive:true,permissions:[]},
  'admins/inactive':{role:'super',isActive:false},
  ...extra,
 });
}
async function withAdminMfaMode(mode,fn){
 const previous=process.env.ADMIN_MFA_MODE;
 process.env.ADMIN_MFA_MODE=mode;
 try{await fn();}finally{
  if(previous===undefined)delete process.env.ADMIN_MFA_MODE;else process.env.ADMIN_MFA_MODE=previous;
 }
}
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

// Phase 3A.4 — `grant` doit désormais passer par le guard administratif
// centralisé (`requireSuperAdmin`), avec rate-limit et audit, au lieu de la
// vérification manuelle de rôle précédemment identifiée en Phase 3A.3.
test('1. Autorisation : super admin actif autorisé, tout le reste refusé',async()=>{
 const {api,store}=grantFixture();
 const result=await api.grant(grantReq());
 assert.deepEqual(result,{saved:true});
 assert.equal(store.get('partner_qr_managers/beneficiary/establishments/'+keyFor('restaurant','r')).active,true);
});
test('1b. Sous-admin (même avec permissions) refusé',async()=>{
 const {api}=grantFixture();
 await assert.rejects(api.grant({auth:{uid:'subby'},data:grantReq().data}),{code:'permission-denied'});
});
test('1c. Super admin inactif refusé',async()=>{
 const {api}=grantFixture();
 await assert.rejects(api.grant({auth:{uid:'inactive'},data:grantReq().data}),{code:'permission-denied'});
});
test('1d. Utilisateur sans document admin refusé',async()=>{
 const {api}=grantFixture();
 await assert.rejects(api.grant({auth:{uid:'ghost'},data:grantReq().data}),{code:'permission-denied'});
});
test('1e. Requête non authentifiée refusée',async()=>{
 const {api}=grantFixture();
 await assert.rejects(api.grant({data:grantReq().data}),{code:'unauthenticated'});
});

test('2. MFA : suit le comportement du guard central (log puis enforce)',async()=>{
 const {api}=grantFixture();
 // Mode par défaut ('log') : aucun second facteur dans ce jeton de test,
 // mais l'opération n'est jamais bloquée — comportement attendu, inchangé.
 await withAdminMfaMode('log',async()=>{
  const r=await api.grant(grantReq({establishmentId:'r'}));
  assert.deepEqual(r,{saved:true});
 });
 // Mode 'enforce' simulé uniquement dans cet environnement de test en
 // mémoire (jamais sur PREPROD/PRODUCTION) : sans claim MFA, refusé.
 const {api:apiEnforce}=grantFixture();
 await withAdminMfaMode('enforce',async()=>{
  await assert.rejects(apiEnforce.grant(grantReq()),{code:'permission-denied'});
 });
 // Avec un jeton portant le claim MFA, 'enforce' autorise l'opération.
 const {api:apiMfa}=grantFixture();
 await withAdminMfaMode('enforce',async()=>{
  const withMfa={auth:{uid:'boss',token:{firebase:{sign_in_second_factor:'totp'}}},data:grantReq().data};
  const r=await apiMfa.grant(withMfa);
  assert.deepEqual(r,{saved:true});
 });
});

test('3. Rate-limit : appels normaux autorisés, dépassement refusé',async()=>{
 const {api,auditLog}=grantFixture();
 for(let i=0;i<10;i++){
  await api.grant(grantReq({establishmentId:'r',active:i%2===0}));
 }
 assert.equal(auditLog.length,10);
 await assert.rejects(api.grant(grantReq({establishmentId:'r'})),{code:'resource-exhausted'});
 // L'appel refusé par le rate-limit n'atteint jamais l'écriture ni l'audit.
 assert.equal(auditLog.length,10);
});

test('4. Audit : attribution et révocation journalisées, échecs jamais présentés comme réussis',async()=>{
 const {api,auditLog}=grantFixture();
 await api.grant(grantReq({active:true}));
 assert.deepEqual(auditLog[0],{
  userId:'boss',userType:'admin',action:'grant_partner_qr_manager',
  targetId:'beneficiary',metadata:{kind:'restaurant',establishmentId:'r',active:true},
 });
 await api.grant(grantReq({active:false}));
 assert.deepEqual(auditLog[1],{
  userId:'boss',userType:'admin',action:'revoke_partner_qr_manager',
  targetId:'beneficiary',metadata:{kind:'restaurant',establishmentId:'r',active:false},
 });
 // Un refus (ici : sous-admin) ne doit jamais produire de ligne d'audit.
 const {api:apiDenied,auditLog:deniedLog}=grantFixture();
 await assert.rejects(apiDenied.grant({auth:{uid:'subby'},data:grantReq().data}));
 assert.equal(deniedLog.length,0);
});

test('5. Non-régression : validation des paramètres et établissement cible',async()=>{
 const {api}=grantFixture();
 await assert.rejects(api.grant({auth:{uid:'boss'},data:{uid:'beneficiary',kind:'inexistant',establishmentId:'r',active:true}}),{code:'invalid-argument'});
 await assert.rejects(api.grant({auth:{uid:'boss'},data:{uid:'',kind:'restaurant',establishmentId:'r',active:true}}),{code:'invalid-argument'});
 await assert.rejects(api.grant({auth:{uid:'boss'},data:{uid:'beneficiary',kind:'restaurant',establishmentId:'r',active:'yes'}}),{code:'invalid-argument'});
 await assert.rejects(api.grant({auth:{uid:'boss'},data:{uid:'beneficiary',kind:'restaurant',establishmentId:'does-not-exist',active:true}}),{code:'failed-precondition'});
});
test('5b. Révocation ne requiert pas que l\'établissement existe encore',async()=>{
 const {api,store}=grantFixture();
 await api.grant({auth:{uid:'boss'},data:{uid:'beneficiary',kind:'restaurant',establishmentId:'disparu',active:false}});
 assert.equal(store.get('partner_qr_managers/beneficiary/establishments/'+keyFor('restaurant','disparu')).active,false);
});
test('5c. Les autres fonctions (manage/resolve/sync/list) restent inchangées',async()=>{
 const {api}=grantFixture();
 assert.ok(typeof api.manage==='function'&&typeof api.resolve==='function'&&typeof api.sync==='function'&&typeof api.list==='function');
});
