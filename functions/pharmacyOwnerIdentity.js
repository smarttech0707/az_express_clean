'use strict';
const {requireSuperAdmin}=require('./adminGuards');
// A session's currentUid and knowledge of a shared pharmacy password are NOT
// proof of personal ownership. Enrollment needs admin nomination and consent
// from the nominated, permanent Auth user. Neither step deletes an account.
function buildPharmacyOwnerIdentity({db,auth,admin,HttpsError,clock=Date.now}) {
 const validId=x=>typeof x==='string'&&x.length>0&&x.length<=128&&!x.includes('/');
 const recent=r=>r.auth&&r.auth.token?.firebase?.sign_in_provider!=='anonymous'&&
  Number.isFinite(r.auth.token?.auth_time)&&clock()/1000-r.auth.token.auth_time>=0&&clock()/1000-r.auth.token.auth_time<=300;
 return async request=>{
  const {action,uid,pharmacyId}=request.data||{};
  if(!recent(request))throw new HttpsError('unauthenticated','Authentification personnelle recente requise');
  let target=request.auth.uid;
  if(action==='nominate'){
   await requireSuperAdmin({request,db});
   if(!validId(uid)||!validId(pharmacyId))throw new HttpsError('invalid-argument','Identifiants invalides');
   target=uid;
   const user=await auth.getUser(target);
   if(user.disabled||!user.providerData?.length)throw new HttpsError('failed-precondition','Compte personnel permanent requis');
  }else if(!['accept','inspect'].includes(action))throw new HttpsError('invalid-argument','Action invalide');
  const binding=db.collection('pharmacy_owners').doc(target);
  const invitation=db.collection('pharmacy_owner_invitations').doc(target);
  return db.runTransaction(async tx=>{
   const [bound,inv,tombstone,deletion]=await Promise.all([tx.get(binding),tx.get(invitation),tx.get(db.collection('account_tombstones').doc(target)),tx.get(db.collection('account_deletions').doc(target))]);
   if(tombstone.exists||deletion.exists)throw new HttpsError('failed-precondition','Compte en cours de suppression');
   const id=action==='nominate'?pharmacyId:inv.data()?.pharmacyId;
   if(!validId(id)||action!=='nominate'&&(!inv.exists||inv.data().expiresAt<clock()))throw new HttpsError('failed-precondition','Invitation absente ou expiree');
   const pharmacy=await tx.get(db.collection('pharmacies').doc(id));
   if(!pharmacy.exists||pharmacy.data().isDeleted===true)throw new HttpsError('failed-precondition','Etablissement indisponible');
   if(action==='inspect')return {pharmacyId:id};
   if(bound.exists){
    if(bound.data().pharmacyId!==id||bound.data().isDeleted===true)throw new HttpsError('failed-precondition','Liaison existante non modifiable');
    return {linked:true};
   }
   if(action==='nominate'){
    if(inv.exists&&inv.data().pharmacyId!==id)throw new HttpsError('failed-precondition','Invitation differente deja presente');
    tx.set(invitation,{pharmacyId:id,nominatedBy:request.auth.uid,expiresAt:clock()+24*60*60*1000,createdAt:admin.firestore.FieldValue.serverTimestamp()});
    return {awaitingOwnerConsent:true};
   }
   tx.create(binding,{pharmacyId:id,uid:target,nominatedBy:inv.data().nominatedBy,acceptedAt:admin.firestore.FieldValue.serverTimestamp()});
   tx.update(invitation,{accepted:true});
   return {linked:true};
  });
 };
}
module.exports={buildPharmacyOwnerIdentity};
