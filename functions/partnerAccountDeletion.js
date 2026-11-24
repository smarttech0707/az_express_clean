'use strict';
const {randomUUID}=require('node:crypto');
const {readDeletionScope}=require('./accountDeletionScope');
const {relatedPersonalPatch}=require('./accountRelatedPersonalData');
const {inspectCleanup,eraseProfileChildren,eraseAiData,failurePatch}=require('./accountCleanup');
// L2 : même protocole de fermeture que accountDeletion.js (tombstone phase/epoch, T2b, F) et moteur d'obligations en plus.
const closure=require('./accountClosureProtocol');
const {inspectProfiles}=require('./accountObligationsInspector');
const {INSPECTOR_TERMINAL_STATUSES}=require('./accountObligations');
// Mission 7E-64 : même plafond de tentatives que le moteur client/livreur (accountDeletion.js).
const MAX_ATTEMPTS=6;
const PERSONAL=['name','fullName','firstName','lastName','phone','email','identifiant','address','photoUrl','fcmToken','token','lat','lng','latitude','longitude','deliveryOfferSession','password','accessCode','birthDate','identityNumber','identityPhotoUrl','idPhotoUrl','idNumber','dateOfBirth','contactPhone','location','currentPosition','depositAccounts','ownerName','operatorNumbers','agencyName'];
function buildPartnerAccountDeletion({db,auth,admin,clock,eraseAssets,quietMs,auditStrict=async()=>{},auditInfo=async()=>{}}){
 const stamp=()=>admin.firestore.Timestamp.fromMillis(clock());
 // Un appel du moteur par identité (Q9) ; l'identifiant est celui de l'établissement pour les rôles à établissement.
 // Les rôles que le moteur ne couvre pas (agents, flotte) restent soumis aux seuls contrôles de readDeletionScope.
 const inspectEngine=(tx,uid,scope)=>inspectProfiles(tx,db,{accountUid:uid,atMs:clock(),terminalStatuses:INSPECTOR_TERMINAL_STATUSES.accountDeletionScope,
  entries:scope.profiles.map(p=>({role:p.role,ids:[p.businessPath?p.businessPath.split('/')[1]:p.ref.id]}))});
 // scope.reason (motifs historiques) prime ; sinon le moteur. `blocking` : toute autre valeur que false bloque.
 const inspectAll=async(tx,uid)=>{
  const scope=await readDeletionScope(tx,db,uid);
  if(scope.reason)return {scope,blocking:true,reason:scope.reason,digest:null,snapshot:null};
  const eng=await inspectEngine(tx,uid,scope);
  return {scope,blocking:eng.blocking,reason:eng.reason,digest:eng.digest,snapshot:eng.snapshot};
 };
 return async uid=>{
  const ref=db.collection('account_deletions').doc(uid),lease=randomUUID();
  const action=await db.runTransaction(async tx=>{
   const j=(await tx.get(ref)).data();
   const cfg=(await tx.get(db.doc('operations_control/account_deletion'))).data();
   if(!j||j.state==='completed'||!j.consentVerified||cfg?.enabled!==true||cfg.partnerInventoryVersion!==1)return null;
   if(j.allProfilesConsent!==true){tx.update(ref,{state:'blocked',reason:'all_profiles_consent_required',reviewRequired:true,nextAttemptAt:null});return null;}
   if(j.leaseUntil>clock()||j.quarantinedAt&&clock()<j.quarantinedAt+quietMs)return null;
   // Ordre de lecture fixe (réserve C2 / L0-F) : tombstone d'abord, puis le périmètre, puis le moteur.
   const tomb=await closure.readTombstone(tx,db,uid);
   const all=await inspectAll(tx,uid);
   const scope={...all.scope};
   if(all.blocking&&!scope.reason)scope.reason=all.reason;
   // Pending deletion prevents new activity but does not suspend existing work.
   if(scope.reason&&j.authDeleted!==true&&tomb.view.exists&&tomb.view.phase==='sealed'){
    // Obligation ou écart découvert alors que le compte est scellé : arrêt + alerte, jamais de reprise automatique (comme accountDeletion.js).
    tx.update(ref,{state:'blocked',reason:closure.REASON.SEALED_OBLIGATION,blockedDetail:scope.reason,reviewRequired:true,nextAttemptAt:null,leaseUntil:0});
    return {alert:closure.REASON.SEALED_OBLIGATION};
   }
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
    if(tomb.view.exists){tx.update(ref,{state:'blocked',reason:closure.REASON.EXISTING_TOMBSTONE,reviewRequired:true,nextAttemptAt:null});return null;}
    tx.create(tomb.ref,closure.closingTombstone({createdAt:stamp(),now:clock()}));
    for(const p of scope.profiles)tx.update(p.ref,{deletionRequested:true,isOnline:false,isAvailable:false,isSuspended:true});
    for(const business of scope.businessesToFreeze)tx.update(business,{deletionRequested:true});
    tx.update(ref,{state:'quarantined',reason:'waiting_for_inflight_operations',scopePaths:paths,quarantinedAt:clock(),nextAttemptAt:clock()+quietMs});return null;
   }
   const entry=closure.planEntry(tomb);
   if(entry.kind==='blocked'){tx.update(ref,{state:'blocked',reason:entry.reason,reviewRequired:true,nextAttemptAt:null,leaseUntil:0});return {alert:entry.reason};}
   if(entry.kind==='sealed'){
    // Reprise d'un dossier scellé (§3.6) : jamais de déverrouillage ; écart = arrêt + alerte, le tombstone reste scellé.
    const plan=closure.planResume({tomb,job:j,reinspection:all});
    if(!plan.ok){tx.update(ref,{state:'blocked',reason:plan.reason,reviewRequired:true,nextAttemptAt:null,leaseUntil:0});return {alert:plan.reason};}
    tx.update(ref,{lease,leaseUntil:clock()+180000,nextAttemptAt:clock()+180000});return {...scope,resumeSealed:true};
   }
   tx.update(ref,{lease,leaseUntil:clock()+180000,nextAttemptAt:clock()+180000,closureEpoch:entry.epoch,snapshotDigest:all.digest,financialSnapshot:all.snapshot});return scope;
  });
  if(!action)return;
  if(action.alert){await auditInfo({userId:uid,userType:'partner',action:'account_deletion_closure_alert',targetId:uid,status:'blocked',metadata:{reason:action.alert}});return;}
  try{
   const cur=(await ref.get()).data()||{};
   // Avant TOUTE suppression Auth : sous-collection inconnue (profil ou AZ IA) = revue manuelle, comptes intacts.
   const pre=await inspectCleanup(db,action.profiles.map(p=>p.ref),uid);
   if(pre.reason){
    await ref.update({state:cur.authDeleted===true?'cleanup_pending':'blocked',reason:pre.reason,blockedDetail:pre.collections,reviewRequired:true,nextAttemptAt:null,leaseUntil:0});
    await auditInfo({userId:uid,userType:'partner',action:'account_deletion_blocked',targetId:uid,status:'blocked',metadata:{reason:pre.reason,collections:pre.collections}});
    return;
   }
   if(cur.authDeleted!==true)await auditStrict({userId:uid,userType:'partner',action:'account_deletion_auth_delete',targetId:uid,metadata:{roles:action.profiles.map(p=>p.role)}});
   // Désactivation Auth, T2b (scellement), F (fence), puis suppression Auth ; `deleteUser` n'est jamais appelé avant T2b et F.
   if(cur.authDeleted===true)await closure.markAuthDeletedTx(db,{uid,now:clock()});
   else{
    const out=await closure.sealAndDeleteAuth({db,auth,uid,lease,resume:action.resumeSealed===true,clock,
     reinspect:async tx=>{const r=await inspectAll(tx,uid);return {blocking:r.blocking,reason:r.reason,digest:r.digest};}});
    if(!out.ok){
     await ref.update(closure.blockedPatch((await ref.get()).data(),{reason:out.reason,now:clock(),retryMs:3600000,maxAttempts:MAX_ATTEMPTS}));
     await auditInfo({userId:uid,userType:'partner',action:'account_deletion_closure_blocked',targetId:uid,status:'blocked',metadata:{reason:out.reason,authReactivated:out.reactivated===true}});
     return;
    }
   }
   await ref.update({state:'cleanup_pending',authDeleted:true,reason:'personal_data_cleanup',nextAttemptAt:clock()+3600000});
   for(const p of action.profiles){
    // Never remove business assets: only explicit personal UID prefixes.
    await eraseAssets(uid,p.role);
   }
   if(!await eraseProfileChildren(db,action.profiles.map(p=>p.ref)))return;
   if(!(await eraseAiData(db,uid)).done)return;
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
   await db.runTransaction(async tx=>{const j=(await tx.get(ref)).data();if(j?.lease===lease&&j.state!=='completed')tx.update(ref,failurePatch(j,{now:clock(),retryMs:3600000,maxAttempts:MAX_ATTEMPTS}));});
  }
 };
}
module.exports={buildPartnerAccountDeletion};
