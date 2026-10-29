'use strict';
const {randomUUID,createHash}=require('node:crypto');
const COLLECTIONS=Object.freeze({restaurant:'restaurants',seller:'sellers',pharmacie:'pharmacies',boulangerie:'boulangeries'});
const validId=x=>typeof x==='string'&&x.length>0&&x.length<=1500&&!x.includes('/');
const keyFor=(kind,id)=>createHash('sha256').update(kind+'\0'+id).digest('hex');
function available(data){return !!data&&data.isDeleted!==true&&data.deletionRequested!==true&&data.isSuspended!==true&&data.isActive!==false&&!['pending','rejected','suspended','deleted'].includes(data.status);}
function publicView(kind,data){
  // Explicit allowlist: never return profile documents, owner identity, GPS,
  // phone, wallet, credentials or tokens to anonymous visitors.
  return {kind,name:typeof data.name==='string'?data.name.slice(0,160):'Etablissement AZ Express'};
}
function buildPartnerQr({db,auth,HttpsError,baseUrl='https://az-express-b0469.web.app',newId=randomUUID}){
  async function ensure(tx,kind,id){
    const source=await tx.get(db.collection(COLLECTIONS[kind]).doc(id));
    const ref=db.collection('partner_qr').doc(keyFor(kind,id));
    const existing=await tx.get(ref);
    if(!source.exists)throw new HttpsError('not-found','Etablissement introuvable');
    if(!available(source.data()))throw new HttpsError('failed-precondition','Etablissement indisponible');
    if(existing.exists)return existing.data();
    const token=newId();
    const data={kind,establishmentId:id,token};
    tx.create(ref,data);
    tx.create(db.collection('partner_qr_tokens').doc(token),{kind,establishmentId:id});
    return data;
  }
  const response=data=>({token:data.token,url:baseUrl+'/partenaire/'+data.token});
  async function manage(request){
    const uid=request.auth?.uid,{kind,establishmentId:id}=request.data||{};
    if(!uid)throw new HttpsError('unauthenticated','Connexion requise');
    if(!Object.hasOwn(COLLECTIONS,kind)||!validId(id))throw new HttpsError('invalid-argument','Etablissement invalide');
    return db.runTransaction(async tx=>{
      const [admin,tomb,source]=await Promise.all([tx.get(db.collection('admins').doc(uid)),tx.get(db.collection('account_tombstones').doc(uid)),tx.get(db.collection(COLLECTIONS[kind]).doc(id))]);
      if(tomb.exists)throw new HttpsError('permission-denied','Compte indisponible');
      let allowed=admin.exists&&admin.data().isActive===true&&admin.data().role==='super';
      if(!allowed){const grant=(await tx.get(db.collection('partner_qr_managers').doc(uid).collection('establishments').doc(keyFor(kind,id)))).data();allowed=grant?.active===true&&grant.kind===kind&&grant.establishmentId===id;}
      if(!allowed&&['seller','boulangerie'].includes(kind))allowed=uid===id;
      if(!allowed&&kind==='restaurant')allowed=(await tx.get(db.collection('restaurant_owners').doc(uid))).data()?.restaurantId===id;
      if(!allowed&&kind==='pharmacie'){
        const binding=(await tx.get(db.collection('pharmacy_owners').doc(uid))).data();
        allowed=binding?.uid===uid&&binding?.pharmacyId===id&&binding?.isDeleted!==true || source.data()?.currentUid===uid;
      }
      if(!allowed)throw new HttpsError('permission-denied','Etablissement non autorise');
      const data=await ensure(tx,kind,id);
      return {...response(data),...publicView(kind,source.data())};
    });
  }
  async function resolve(request){
    const token=request.data?.token;
    if(typeof token!=='string'||!/^[-a-zA-Z0-9]{20,80}$/.test(token))throw new HttpsError('invalid-argument','QR invalide');
    const record=(await db.collection('partner_qr_tokens').doc(token).get()).data();
    if(!record||!Object.hasOwn(COLLECTIONS,record.kind))return {available:false};
    const source=(await db.collection(COLLECTIONS[record.kind]).doc(record.establishmentId).get()).data();
    if(!available(source))return {available:false};
    return {available:true,...publicView(record.kind,source)};
  }
  async function sync(kind,id){
    try{await db.runTransaction(tx=>ensure(tx,kind,id));}
    catch(e){if(!['not-found','failed-precondition'].includes(e.code))throw e;}
  }
  async function grant(request){
    const actor=request.auth?.uid,{uid,kind,establishmentId:id,active}=request.data||{};
    if(!actor)throw new HttpsError('unauthenticated','Connexion requise');
    if(!validId(uid)||!Object.hasOwn(COLLECTIONS,kind)||!validId(id)||typeof active!=='boolean')throw new HttpsError('invalid-argument','Parametres invalides');
    // Validate the actor before looking up any target Auth account.
    const actorProfile=(await db.collection('admins').doc(actor).get()).data();
    if(actorProfile?.role!=='super'||actorProfile?.isActive!==true)throw new HttpsError('permission-denied','Super-admin requis');
    if(active){
      let user;
      try{user=await auth.getUser(uid);}catch(_){throw new HttpsError('failed-precondition','Compte Firebase cible non verifie');}
      if(user.uid!==uid||user.disabled||!user.providerData?.length)throw new HttpsError('failed-precondition','Compte personnel permanent requis');
    }
    await db.runTransaction(async tx=>{
      const [a,t,source]=await Promise.all([tx.get(db.collection('admins').doc(actor)),tx.get(db.collection('account_tombstones').doc(uid)),tx.get(db.collection(COLLECTIONS[kind]).doc(id))]);
      if(a.data()?.role!=='super'||a.data()?.isActive!==true)throw new HttpsError('permission-denied','Super-admin requis');
      if(active&&(t.exists||!source.exists))throw new HttpsError('failed-precondition','Compte ou etablissement indisponible');
      tx.set(db.collection('partner_qr_managers').doc(uid).collection('establishments').doc(keyFor(kind,id)),{kind,establishmentId:id,active,grantedBy:actor});
    });
    return {saved:true};
  }
  async function list(request){
    const uid=request.auth?.uid;
    if(!uid)throw new HttpsError('unauthenticated','Connexion requise');
    if((await db.collection('account_tombstones').doc(uid).get()).exists)throw new HttpsError('permission-denied','Compte indisponible');
    const candidates=new Map();
    const add=(kind,id)=>{if(validId(id))candidates.set(keyFor(kind,id),{kind,establishmentId:id});};
    add('seller',uid);add('boulangerie',uid);
    const [restaurant,pharmacy,grants]=await Promise.all([
      db.collection('restaurant_owners').doc(uid).get(),db.collection('pharmacy_owners').doc(uid).get(),
      db.collection('partner_qr_managers').doc(uid).collection('establishments').limit(101).get()]);
    if(grants.size>100)throw new HttpsError('resource-exhausted','Plus de 100 liaisons : contactez le support');
    if(restaurant.data()?.isDeleted!==true)add('restaurant',restaurant.data()?.restaurantId);
    if(pharmacy.data()?.uid===uid&&pharmacy.data()?.isDeleted!==true)add('pharmacie',pharmacy.data()?.pharmacyId);
    for(const g of grants.docs){const d=g.data();if(d.active===true&&Object.hasOwn(COLLECTIONS,d.kind))add(d.kind,d.establishmentId);}
    // Legacy pharmacy sessions retain only their existing server-assigned access.
    const legacy=await db.collection('pharmacies').where('currentUid','==',uid).limit(101).get();
    if(legacy.size>100)throw new HttpsError('resource-exhausted','Trop de liaisons');
    for(const p of legacy.docs)add('pharmacie',p.id);
    const items=[];
    for(const candidate of candidates.values()){
      const data=(await db.collection(COLLECTIONS[candidate.kind]).doc(candidate.establishmentId).get()).data();
      if(data)items.push({...candidate,...publicView(candidate.kind,data),available:available(data)});
    }
    return {establishments:items};
  }
  return {manage,resolve,sync,list,grant};
}
module.exports={buildPartnerQr,keyFor,available,publicView,COLLECTIONS};
