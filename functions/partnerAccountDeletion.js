'use strict';
const {randomUUID}=require('node:crypto');
const {readDeletionScope}=require('./accountDeletionScope');
const {relatedPersonalPatch}=require('./accountRelatedPersonalData');
const PERSONAL=['name','fullName','firstName','lastName','phone','email','identifiant','address','photoUrl','fcmToken','token','lat','lng','latitude','longitude','deliveryOfferSession','password','accessCode','birthDate','identityNumber','identityPhotoUrl','idPhotoUrl','idNumber','dateOfBirth','contactPhone','location','currentPosition','depositAccounts','ownerName','operatorNumbers','agencyName'];
function buildPartnerAccountDeletion({db,auth,admin,clock,eraseAssets,quietMs}){
 const stamp=()=>admin.firestore.Timestamp.fromMillis(clock());
 return async uid=>{
  const ref=db.collection('account_deletions').doc(uid),lease=randomUUID();
  const action=await db.runTransaction(async tx=>{
   const j=(await tx.get(ref)).data();
   const cfg=(await tx.get(db.doc('operations_control/account_deletion'))).data();
   if(!j||j.state==='completed'||!j.consentVerified||cfg?.enabled!==true||cfg.partnerInventoryVersion!==1)return null;
   if(j.allProfilesConsent!==true){tx.update(ref,{state:'blocked',reason:'all_profiles_consent_required',reviewRequired:true,nextAttemptAt:null});return null;}
   if(j.leaseUntil>clock()||j.quarantinedAt&&clock()<j.quarantinedAt+quietMs)return null;
   const scope=await readDeletionScope(tx,db,uid);
   // Pending deletion prevents new activity but does not suspend existing work.
   if(scope.reason){
    for(const p of scope.profiles||[])tx.update(p.ref,{deletionRequested:true});
    for(const business of scope.businessesToFreeze||[])tx.update(business,{deletionRequested:true});
    tx.update(ref,{state:j.authDeleted?'cleanup_pending':'blocked',reason:scope.reason,reviewRequired:true,nextAttemptAt:clock()+3600000});return null;
   }
   const paths=scope.profiles.map(p=>p.ref.path).sort();
   if(j.scopePaths&&JSON.stringify(paths)!==JSON.stringify(j.scopePaths)){
    tx.update(ref,{state:'blocked',reason:'identity_scope_changed',reviewRequired:true,nextAttemptAt:null});return null;
   }
   if(!j.quarantinedAt){
    const tomb=await tx.get(db.doc('account_tombstones/'+uid));
    if(tomb.exists){tx.update(ref,{state:'blocked',reason:'existing_tombstone_review',reviewRequired:true,nextAttemptAt:null});return null;}
    tx.create(tomb.ref,{createdAt:stamp(),state:'deleting'});
    for(const p of scope.profiles)tx.update(p.ref,{deletionRequested:true,isOnline:false,isAvailable:false,isSuspended:true});
    for(const business of scope.businessesToFreeze)tx.update(business,{deletionRequested:true});
    tx.update(ref,{state:'quarantined',reason:'waiting_for_inflight_operations',scopePaths:paths,quarantinedAt:clock(),nextAttemptAt:clock()+quietMs});return null;
   }
   tx.update(ref,{lease,leaseUntil:clock()+180000,nextAttemptAt:clock()+180000});return scope;
  });
  if(!action)return;
  try{
   try{await auth.updateUser(uid,{disabled:true});await auth.revokeRefreshTokens(uid);await auth.deleteUser(uid);}catch(e){if(e.code!=='auth/user-not-found')throw e;}
   try{await auth.getUser(uid);throw Error('AUTH_NOT_DELETED');}catch(e){if(e.code!=='auth/user-not-found')throw e;}
   await ref.update({state:'cleanup_pending',authDeleted:true,reason:'personal_data_cleanup',nextAttemptAt:clock()+3600000});
   for(const p of action.profiles){
    // Never remove business assets: only explicit personal UID prefixes.
    await eraseAssets(uid,p.role);
    for(const children of await p.ref.listCollections()){
     if(children.id==='wallet_transactions')continue;
     if(children.id!=='notifications')throw Error('UNKNOWN_PROFILE_CHILDREN');
     const page=await children.limit(100).get();
     if(!page.empty){const batch=db.batch();for(const doc of page.docs)batch.delete(doc.ref);await batch.commit();}
     if(page.size===100)return;
    }
   }
   await db.runTransaction(async tx=>{
    const j=(await tx.get(ref)).data();if(j.lease!==lease||j.state==='completed')return;
    const scope=await readDeletionScope(tx,db,uid);
    if(scope.reason){tx.update(ref,{state:'cleanup_pending',reason:scope.reason,reviewRequired:true,nextAttemptAt:clock()+3600000});return;}
    if(JSON.stringify(scope.profiles.map(p=>p.ref.path).sort())!==JSON.stringify(j.scopePaths))throw Error('SCOPE_CHANGED');
    for(const p of scope.profiles){
     const patch={isDeleted:true,deletionRequested:true,isOnline:false,isAvailable:false,isSuspended:true,deletedAt:stamp()};
     for(const key of PERSONAL)if(Object.hasOwn(p.profile,key))patch[key]=admin.firestore.FieldValue.delete();
     // Shared business documents and all financial fields stay untouched.
     tx.update(p.ref,patch);
    }
    const roles=new Set(scope.profiles.map(p=>p.role));
    // Business identities belong to the establishment, not the departing owner.
    for(const doc of scope.related){const patch=relatedPersonalPatch(doc.data(),uid,roles,admin.firestore.FieldValue.delete());if(Object.keys(patch).length)tx.update(doc.ref,patch);}
    tx.update(ref,{state:'completed',reason:null,authDeleted:true,profileAnonymized:true,completedAt:stamp(),nextAttemptAt:null,reviewRequired:false,retentionReviewRequired:true});
   });
  }catch(_){
   await db.runTransaction(async tx=>{const j=(await tx.get(ref)).data();if(j?.lease===lease&&j.state!=='completed')tx.update(ref,{state:'cleanup_pending',reason:'server_retry_required',reviewRequired:true,nextAttemptAt:clock()+3600000});});
  }
 };
}
module.exports={buildPartnerAccountDeletion};
