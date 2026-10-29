"use strict";
const {createHash,timingSafeEqual,randomUUID}=require('node:crypto');
const ROLES={client:'clients',livreur:'livreurs'};
const {ROLE_COLLECTIONS,readDeletionIdentity}=require('./accountDeletionIdentity');
const TERMINAL=new Set(['delivered','cancelled','expired','completed','refunded','failed_refunded','failed','rejected']);
const LIMIT=201, QUIET_MS=15*60*1000, RETRY_MS=60*60*1000;
const digest=value=>createHash('sha256').update(value).digest('hex');
const validToken=t=>typeof t==='string' && /^[a-f0-9]{64}$/.test(t);
const publicState=j=>({status:j.state,reason:j.reason||null,requestId:j.uid,
  authDeleted:j.authDeleted===true,profileAnonymized:j.profileAnonymized===true,
  reviewRequired:j.reviewRequired===true});
async function assertAccountEnabled(db,uid,HttpsError){
 if(uid && (await db.collection('account_tombstones').doc(uid).get()).exists)
  throw new HttpsError('permission-denied','ACCOUNT_DELETION_IN_PROGRESS');
}
function buildAccountDeletion({db,auth,admin,HttpsError,clock=Date.now,eraseAssets=async()=>{throw new Error('ASSET_CLEANER_REQUIRED');}}){
 const processPartners=require('./partnerAccountDeletion').buildPartnerAccountDeletion({db,auth,admin,clock,eraseAssets,quietMs:QUIET_MS});
 const jobRef=uid=>db.collection('account_deletions').doc(uid);
 const stamp=()=>admin.firestore.Timestamp.fromMillis(clock());
 async function inspect(tx,uid,role){
  const profileRef=db.collection(ROLES[role]).doc(uid),profile=await tx.get(profileRef);
  const p=profile.data();
  if(!p)return {reason:'profile_missing',profileRef};
  if(!Number.isSafeInteger(p.wallet)||p.wallet!==0)return {reason:'balance_regularization_required',profileRef};
  for(const key of ['debt','pendingBalance','reservedBalance','pendingWithdrawal','commissionDebt'])
   if(p[key]!=null && p[key]!==0)return {reason:'balance_regularization_required',profileRef};
  if(p.isOnDelivery===true || p.currentOrderId || p.pendingOrderId)return {reason:'active_mission_or_reference',profileRef};
  // A shared Auth identity must not silently remove access to a different business role.
  for(const col of ['clients','livreurs','admins','sellers','restaurant_owners','pharmacies','boulangeries','ekbine_agents','real_estate_agents','fleet_owners']){
   if(col===ROLES[role])continue;
   if((await tx.get(db.collection(col).doc(uid))).exists)return {reason:'multiple_roles_manual_review',profileRef};
  }
  const related=[];
  const queries=[['orders',role==='client'?'clientId':'driverId'],
   ...['boutique_orders','blanchisserie_orders','eau_boissons_orders','ekbine_orders'].map(c=>[c,role==='client'?'clientId':'driverId']),
   ['wallet_transactions','userId'],['withdrawal_requests','userId']];
  for(const [col,field] of queries){
   const snap=await tx.get(db.collection(col).where(field,'==',uid).limit(LIMIT));
   if(snap.size>=LIMIT)return {reason:'history_requires_manual_review',profileRef};
   for(const doc of snap.docs){
    const d=doc.data();
    if(!TERMINAL.has(d.status))return {reason:'active_or_unresolved_operation',profileRef};
    if(d.refundPending===true || d.needsReview===true || d.paymentStatus==='pending')return {reason:'financial_regularization_required',profileRef};
    related.push(doc);
    if(related.length>=200)return {reason:'history_requires_manual_review',profileRef};
   }
  }
  return {profileRef,profile:p,related};
 }
 async function process(uid){
  const ref=jobRef(uid),lease=randomUUID();
  const action=await db.runTransaction(async tx=>{
   const snap=await tx.get(ref);if(!snap.exists)return null;
   const j=snap.data();if(j.state==='completed')return null;
   const config=(await tx.get(db.collection('operations_control').doc('account_deletion'))).data();
   if(config?.enabled!==true || config.inventoryVersion!==1){
    tx.update(ref,{state:'pending',reason:'server_rollout_not_enabled',nextAttemptAt:clock()+RETRY_MS});return null;
   }
   if(!j.consentVerified)return null;
   if(config.partnerInventoryVersion===1)return {partnerScope:true};
   if(!ROLES[j.role]){
    tx.update(ref,{state:'blocked',reason:'role_obligations_review_required',reviewRequired:true,nextAttemptAt:null});return null;
   }
   if(j.quarantinedAt && clock()<j.quarantinedAt+QUIET_MS)return null;
   if(j.leaseUntil>clock())return null;
   if(j.authDeleted===true){tx.update(ref,{lease,leaseUntil:clock()+180000,nextAttemptAt:clock()+180000});return j;}
   const check=await inspect(tx,uid,j.role);
   if(check.reason){tx.update(ref,{state:'blocked',reason:check.reason,reviewRequired:true,nextAttemptAt:clock()+RETRY_MS});return null;}
   if(!j.quarantinedAt){
    tx.create(db.collection('account_tombstones').doc(uid),{createdAt:stamp(),state:'deleting'});
    tx.update(check.profileRef,{isOnline:false,isAvailable:false,isSuspended:true});
    tx.update(ref,{state:'quarantined',reason:'waiting_for_inflight_operations',quarantinedAt:clock(),nextAttemptAt:clock()+QUIET_MS});return null;
   }
   tx.update(ref,{lease,leaseUntil:clock()+180000,nextAttemptAt:clock()+180000});
   return j;
  });
  if(!action)return publicState((await ref.get()).data());
  if(action.partnerScope){await processPartners(uid);return publicState((await ref.get()).data());}
  try{
   // Idempotent: an already missing Auth user is the expected retry state.
   try{await auth.updateUser(uid,{disabled:true});await auth.revokeRefreshTokens(uid);await auth.deleteUser(uid);}
   catch(e){if(e.code!=='auth/user-not-found')throw e;}
   try{await auth.getUser(uid);throw new Error('AUTH_DELETION_NOT_CONFIRMED');}
   catch(e){if(e.code!=='auth/user-not-found')throw e;}
   await ref.update({authDeleted:true,state:'cleanup_pending',reason:'personal_data_cleanup',nextAttemptAt:clock()+RETRY_MS});
   // Fixed, UID-scoped prefixes only. Never delete order proofs or accounting assets.
   await eraseAssets(uid,action.role);
   // Non-financial profile children are paginated; unknown collections require review.
   const profileRef=db.collection(ROLES[action.role]).doc(uid);
   for(const collection of await profileRef.listCollections()){
    if(collection.id==='wallet_transactions')continue;
    if(collection.id!=='notifications')throw new Error('PERSONAL_DATA_INVENTORY_REQUIRED');
    const page=await collection.limit(100).get();
    if(!page.empty){const batch=db.batch();for(const d of page.docs)batch.delete(d.ref);await batch.commit();}
    if(page.size===100)return publicState((await ref.get()).data());
   }
   if(action.role==='livreur')await db.collection('driver_requests').doc(uid).delete();
   await db.runTransaction(async tx=>{
    const j=(await tx.get(ref)).data();if(j.state==='completed'||j.lease!==lease)return;
    const check=await inspect(tx,uid,j.role);
    if(check.reason){tx.update(ref,{state:'cleanup_pending',reason:check.reason,reviewRequired:true,nextAttemptAt:clock()+RETRY_MS});return;}
    // Preserve every financial field; remove only explicit personal/contact fields.
    const personal=['name','fullName','firstName','lastName','phone','email','identifiant','address','photoUrl','fcmToken','token','lat','lng','latitude','longitude','deliveryOfferSession','password','accessCode','birthDate','identityNumber','identityPhotoUrl','idPhotoUrl','idNumber','dateOfBirth','contactPhone','location','currentPosition'];
    const patch={isDeleted:true,isOnline:false,isAvailable:false,isSuspended:true,deletedAt:stamp()};
    for(const k of personal)if(Object.hasOwn(check.profile,k))patch[k]=admin.firestore.FieldValue.delete();
    tx.update(check.profileRef,patch);
    const fields=j.role==='client'?['clientName','clientPhone','clientEmail','recipientName','recipientPhone','pickupContactName','pickupContactPhone','deliveryAddress','pickupAddress','latitude','longitude','destLat','destLng','pickupLat','pickupLng','voiceMessage']:['driverName','driverPhone','driverEmail','driverPhotoUrl','driverAcceptanceSelfie'];
    for(const d of check.related){const p={};for(const k of fields)if(Object.hasOwn(d.data(),k))p[k]=admin.firestore.FieldValue.delete();if(Object.keys(p).length)tx.update(d.ref,p);}
    tx.update(ref,{state:'completed',reason:null,authDeleted:true,profileAnonymized:true,completedAt:stamp(),nextAttemptAt:null,
      retentionReviewRequired:true,reviewRequired:false});
   });
  }catch(_){
   // Never copy tokens, credentials, provider errors or personal data into the receipt.
   await ref.update({state:'cleanup_pending',reason:'server_retry_required',reviewRequired:true,nextAttemptAt:clock()+RETRY_MS});
  }
  return publicState((await ref.get()).data());
 }
 async function request(request){
  const uid=request.auth?.uid,role=request.data?.role,token=request.data?.recoveryToken;
  if(!uid || request.auth.token?.firebase?.sign_in_provider==='anonymous')throw new HttpsError('unauthenticated','Connexion requise');
  if(!Object.hasOwn(ROLE_COLLECTIONS,role) || !validToken(token))throw new HttpsError('invalid-argument','Demande invalide');
  const recent=Number.isFinite(request.auth.token?.auth_time) && clock()/1000-request.auth.token.auth_time>=0 && clock()/1000-request.auth.token.auth_time<=300;
  const ref=jobRef(uid);
  await db.runTransaction(async tx=>{
   const old=await tx.get(ref);
   const identity=await readDeletionIdentity(tx,db,uid,role);
   if(!identity)throw new HttpsError('permission-denied','Identite du profil non etablie; verification support necessaire');
   const profileRef=identity.ref;
   if(old.exists){
    if(old.data().role!==role)throw new HttpsError('failed-precondition','Demande existante pour un autre role');
    if(!old.data().consentVerified && recent)tx.update(ref,{consentVerified:true,state:'pending',reason:null,nextAttemptAt:clock()});
    if(recent&&request.data.allProfilesConsent===true)tx.update(ref,{allProfilesConsent:true,nextAttemptAt:clock()});
    if(role==='livreur' && (recent || old.data().consentVerified))tx.update(profileRef,{deletionRequested:true});
    return;
   }
   if(role==='livreur' && recent)tx.update(profileRef,{deletionRequested:true});
   tx.create(ref,{uid,role,profilePath:identity.profilePath,...(identity.businessPath?{businessPath:identity.businessPath}:{}),recoveryHash:digest(token),state:'pending',reason:recent?null:'reauthentication_required',
    consentVerified:recent,allProfilesConsent:recent&&request.data.allProfilesConsent===true,requestedAt:stamp(),reviewAfter:clock()+72*60*60*1000,nextAttemptAt:recent?clock():null});
  });
  return process(uid);
 }
 async function status(request){
  const uid=request.data?.uid,token=request.data?.recoveryToken;
  if(typeof uid!=='string'||!uid||uid.includes('/')||!validToken(token))throw new HttpsError('invalid-argument','Demande invalide');
  const snap=await jobRef(uid).get(),j=snap.data();
  const hash=digest(token);
  if(!j || typeof j.recoveryHash!=='string'||j.recoveryHash.length!==hash.length ||
     !timingSafeEqual(Buffer.from(j.recoveryHash),Buffer.from(hash)))throw new HttpsError('permission-denied','Suivi indisponible');
  // Recovery capability allows only reading this minimal status, never starting deletion.
  return publicState(j);
 }
 async function drain(){
  const jobs=await db.collection('account_deletions').where('nextAttemptAt','<=',clock()).limit(20).get();
  for(const doc of jobs.docs){try{await process(doc.id);}catch(_){/* remains due; no false completion */}}
 }
 return {request,status,process,drain};
}
module.exports={buildAccountDeletion,assertAccountEnabled,QUIET_MS};
