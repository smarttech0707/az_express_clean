"use strict";
const {createHash,timingSafeEqual,randomUUID}=require('node:crypto');
const ROLES={client:'clients',livreur:'livreurs'};
const {ROLE_COLLECTIONS,readDeletionIdentity}=require('./accountDeletionIdentity');
const TERMINAL=new Set(['delivered','cancelled','expired','completed','refunded','failed_refunded','failed','rejected']);
const LIMIT=201, QUIET_MS=15*60*1000, RETRY_MS=60*60*1000;
const {inspectCleanup,eraseProfileChildren,eraseAiData,failurePatch}=require('./accountCleanup');
// L2 : protocole de fermeture (tombstone phase/epoch, scellement T2b, fence F) et moteur d'obligations (s'ajoute à inspect()).
const closure=require('./accountClosureProtocol');
const {inspectObligations,inspectWithdrawals}=require('./accountObligationsInspector');
const {INSPECTOR_TERMINAL_STATUSES}=require('./accountObligations');
// Mission 7E-64 — anti-abus : 5 demandes/heure/compte (checkRateLimit), 10 demandes cumulées par dossier, une demande
// identique dans les 60 s est absorbée sans retraitement, 6 échecs techniques consécutifs = fin des reprises automatiques.
const RATE_MAX=5, RATE_WINDOW_S=3600, MAX_REQUESTS=10, REPEAT_WINDOW_MS=60*1000, MAX_ATTEMPTS=6;
const digest=value=>createHash('sha256').update(value).digest('hex');
const validToken=t=>typeof t==='string' && /^[a-f0-9]{64}$/.test(t);
const publicState=j=>({status:j.state,reason:j.reason||null,requestId:j.uid,
  authDeleted:j.authDeleted===true,profileAnonymized:j.profileAnonymized===true,
  reviewRequired:j.reviewRequired===true});
async function assertAccountEnabled(db,uid,HttpsError){
 if(uid && (await db.collection('account_tombstones').doc(uid).get()).exists)
  throw new HttpsError('permission-denied','ACCOUNT_DELETION_IN_PROGRESS');
}
function buildAccountDeletion({db,auth,admin,HttpsError,clock=Date.now,checkRateLimit=null,logAudit=null,eraseAssets=async()=>{throw new Error('ASSET_CLEANER_REQUIRED');}}){
 const processPartners=require('./partnerAccountDeletion').buildPartnerAccountDeletion({db,auth,admin,clock,eraseAssets,quietMs:QUIET_MS,
  auditStrict:d=>auditStrict(d),auditInfo:d=>auditInfo(d)});
 const jobRef=uid=>db.collection('account_deletions').doc(uid);
 const stamp=()=>admin.firestore.Timestamp.fromMillis(clock());
 // Même schéma que logAudit (index.js). logAudit avale ses erreurs : il ne peut pas servir de verrou avant l'étape
 // irréversible. auditStrict propage l'échec ; auditInfo n'interrompt jamais le traitement. Jamais de jeton ni de donnée personnelle.
 const auditDoc=d=>({userId:d.userId||null,userType:d.userType||'unknown',action:d.action,targetId:d.targetId||null,amount:null,
  status:d.status||'success',metadata:d.metadata||{},createdAt:admin.firestore.FieldValue.serverTimestamp()});
 const auditStrict=async d=>{await db.collection('audit_logs').add(auditDoc(d));};
 const auditInfo=async d=>{try{if(typeof logAudit==='function')await logAudit(d);else await auditStrict(d);}catch(_){/* audit best effort */}};
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
   ['wallet_transactions','userId']];
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
  // L2.2 : retraits classés par le prédicat du moteur (`sent`/`processed` confirmés ne bloquent plus), même position de lecture qu'avant.
  const withdrawals=await inspectWithdrawals(tx,db,{accountUid:uid});
  if(withdrawals.blocking)return {reason:withdrawals.reason,profileRef};
  for(const doc of withdrawals.docs){related.push(doc);if(related.length>=200)return {reason:'history_requires_manual_review',profileRef};}
  return {profileRef,profile:p,related};
 }
 // inspect() d'abord (ses motifs historiques priment), puis le moteur d'obligations. `blocking` : toute autre valeur que false bloque.
 async function inspectAll(tx,uid,role){
  const check=await inspect(tx,uid,role);
  if(check.reason)return {...check,blocking:true,digest:null,snapshot:null};
  const eng=await inspectObligations(tx,db,{role,ids:[uid],terminalStatuses:INSPECTOR_TERMINAL_STATUSES.accountDeletion,atMs:clock(),accountUid:uid});
  return {...check,blocking:eng.blocking,reason:eng.reason,digest:eng.digest,snapshot:eng.snapshot};
 }
 async function process(uid){
  const ref=jobRef(uid),lease=randomUUID();
  const action=await db.runTransaction(async tx=>{
   const snap=await tx.get(ref);if(!snap.exists)return null;
   const j=snap.data();if(j.state==='completed')return null;
   // Plafond atteint : seule une reprise motivée du support (qui remet le compteur à zéro) relance le dossier.
   if(j.reason==='max_attempts_reached')return null;
   const config=(await tx.get(db.collection('operations_control').doc('account_deletion'))).data();
   if(config?.enabled!==true || config.inventoryVersion!==1){
    tx.update(ref,{state:'pending',reason:'server_rollout_not_enabled',nextAttemptAt:clock()+RETRY_MS});return null;
   }
   if(!j.consentVerified)return null;
   // D3 (7E-68) : un UID présent dans `admins` n'est jamais traité automatiquement, quel que soit le rôle demandé
   // (client, livreur ou partenaire) : ni quarantaine, ni suppression Auth. Intervention administrative distincte et tracée.
   if((await tx.get(db.collection('admins').doc(uid))).exists){
    tx.update(ref,{state:'blocked',reason:'admin_account_manual_process',reviewRequired:true,nextAttemptAt:null});return null;
   }
   if(config.partnerInventoryVersion===1)return {partnerScope:true};
   if(!ROLES[j.role]){
    tx.update(ref,{state:'blocked',reason:'role_obligations_review_required',reviewRequired:true,nextAttemptAt:null});return null;
   }
   if(j.quarantinedAt && clock()<j.quarantinedAt+QUIET_MS)return null;
   if(j.leaseUntil>clock())return null;
   if(j.authDeleted===true){tx.update(ref,{lease,leaseUntil:clock()+180000,nextAttemptAt:clock()+180000});return j;}
   // Ordre de lecture fixe (réserve C2 / L0-F) : tombstone, puis profil et collections de l'inspecteur, puis écritures.
   const tomb=await closure.readTombstone(tx,db,uid);
   const check=await inspectAll(tx,uid,j.role);
   if(!j.quarantinedAt){
    // T1 : inspection et moteur non bloquants, aucun tombstone préexistant (jamais écrasé), tombstone `closing` / epoch 0.
    if(check.blocking){tx.update(ref,{state:'blocked',reason:check.reason,reviewRequired:true,nextAttemptAt:clock()+RETRY_MS});return null;}
    if(tomb.view.exists){tx.update(ref,{state:'blocked',reason:closure.REASON.EXISTING_TOMBSTONE,reviewRequired:true,nextAttemptAt:null});return null;}
    tx.create(tomb.ref,closure.closingTombstone({createdAt:stamp(),now:clock()}));
    tx.update(check.profileRef,{isOnline:false,isAvailable:false,isSuspended:true});
    tx.update(ref,{state:'quarantined',reason:'waiting_for_inflight_operations',quarantinedAt:clock(),nextAttemptAt:clock()+QUIET_MS});return null;
   }
   const entry=closure.planEntry(tomb);
   if(entry.kind==='blocked'){tx.update(ref,{state:'blocked',reason:entry.reason,reviewRequired:true,nextAttemptAt:null,leaseUntil:0});return {alert:entry.reason};}
   if(entry.kind==='sealed'){
    // Reprise d'un dossier scellé (§3.6) : jamais de déverrouillage ; mismatch = arrêt + alerte, le tombstone reste scellé.
    const plan=closure.planResume({tomb,job:j,reinspection:check});
    if(!plan.ok){tx.update(ref,{state:'blocked',reason:plan.reason,reviewRequired:true,nextAttemptAt:null,leaseUntil:0});return {alert:plan.reason};}
    tx.update(ref,{lease,leaseUntil:clock()+180000,nextAttemptAt:clock()+180000});
    return {...j,resumeSealed:true};
   }
   // T2 : (re)inspection complète, epoch observé, empreinte du snapshot financier et bail, dans la même transaction.
   if(check.blocking){tx.update(ref,{state:'blocked',reason:check.reason,reviewRequired:true,nextAttemptAt:clock()+RETRY_MS});return null;}
   tx.update(ref,{lease,leaseUntil:clock()+180000,nextAttemptAt:clock()+180000,closureEpoch:entry.epoch,snapshotDigest:check.digest,financialSnapshot:check.snapshot});
   return j;
  });
  if(!action)return publicState((await ref.get()).data());
  if(action.alert){await auditInfo({userId:uid,userType:'unknown',action:'account_deletion_closure_alert',targetId:uid,status:'blocked',metadata:{reason:action.alert}});return publicState((await ref.get()).data());}
  if(action.partnerScope){await processPartners(uid);return publicState((await ref.get()).data());}
  try{
   const profileRef=db.collection(ROLES[action.role]).doc(uid);
   // Avant TOUTE suppression Auth : un élément de nettoyage inconnu bloque le dossier en revue manuelle, compte intact.
   const pre=await inspectCleanup(db,[profileRef],uid);
   if(pre.reason){
    await ref.update({state:action.authDeleted===true?'cleanup_pending':'blocked',reason:pre.reason,blockedDetail:pre.collections,reviewRequired:true,nextAttemptAt:null,leaseUntil:0});
    await auditInfo({userId:uid,userType:action.role,action:'account_deletion_blocked',targetId:uid,status:'blocked',metadata:{role:action.role,reason:pre.reason,collections:pre.collections}});
    return publicState((await ref.get()).data());
   }
   // Journal d'audit exigé AVANT l'étape irréversible : s'il échoue, le compte Auth n'est pas supprimé (reprise ultérieure).
   if(action.authDeleted!==true)await auditStrict({userId:uid,userType:action.role,action:'account_deletion_auth_delete',targetId:uid,metadata:{role:action.role}});
   // Désactivation Auth, T2b (scellement), F (fence), puis suppression Auth ; `deleteUser` n'est jamais appelé avant T2b et F.
   if(action.authDeleted===true)await closure.markAuthDeletedTx(db,{uid,now:clock()});
   else{
    const out=await closure.sealAndDeleteAuth({db,auth,uid,lease,resume:action.resumeSealed===true,clock,
     reinspect:async tx=>{const r=await inspectAll(tx,uid,action.role);return {blocking:r.blocking,reason:r.reason,digest:r.digest};}});
    if(!out.ok){
     await ref.update(closure.blockedPatch((await ref.get()).data(),{reason:out.reason,now:clock(),retryMs:RETRY_MS,maxAttempts:MAX_ATTEMPTS}));
     await auditInfo({userId:uid,userType:action.role,action:'account_deletion_closure_blocked',targetId:uid,status:'blocked',metadata:{role:action.role,reason:out.reason,authReactivated:out.reactivated===true}});
     return publicState((await ref.get()).data());
    }
   }
   await ref.update({authDeleted:true,state:'cleanup_pending',reason:'personal_data_cleanup',nextAttemptAt:clock()+RETRY_MS});
   // Fixed, UID-scoped prefixes only. Never delete order proofs or accounting assets.
   await eraseAssets(uid,action.role);
   // Notifications (paginées) ; wallet_transactions conservé ; toute autre sous-collection a déjà bloqué le dossier plus haut.
   if(!await eraseProfileChildren(db,[profileRef]))return publicState((await ref.get()).data());
   // Données AZ IA identifiables par UID (voir accountCleanup.js : preuve de consentement et actions confirmées conservées).
   const ai=await eraseAiData(db,uid);
   if(!ai.done)return publicState((await ref.get()).data());
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
   await auditInfo({userId:uid,userType:action.role,action:'account_deletion_completed',targetId:uid,metadata:{role:action.role,aiData:ai.counts}});
  }catch(_){
   // Never copy tokens, credentials, provider errors or personal data into the receipt.
   const patch=failurePatch((await ref.get()).data(),{now:clock(),retryMs:RETRY_MS,maxAttempts:MAX_ATTEMPTS});
   await ref.update(patch);
   await auditInfo({userId:uid,userType:action.role,action:'account_deletion_failed',targetId:uid,status:'failed',metadata:{role:action.role,reason:patch.reason,attempts:patch.attempts}});
  }
  return publicState((await ref.get()).data());
 }
 async function request(request){
  const uid=request.auth?.uid,role=request.data?.role,token=request.data?.recoveryToken;
  if(!uid || request.auth.token?.firebase?.sign_in_provider==='anonymous')throw new HttpsError('unauthenticated','Connexion requise');
  if(!Object.hasOwn(ROLE_COLLECTIONS,role) || !validToken(token))throw new HttpsError('invalid-argument','Demande invalide');
  // Sans limiteur injecté, la fonction refuse de traiter : jamais de suppression sans protection anti-abus.
  if(typeof checkRateLimit!=='function')throw new HttpsError('failed-precondition','RATE_LIMITER_REQUIRED');
  // Mission 7E-74 : passerelle absente, fermée ou illisible => refus net AVANT toute écriture (aucun dossier, aucun marqueur
  // deletionRequested, aucune quarantaine, aucun audit, aucune écriture du limiteur). Même condition que process() ; une erreur
  // de lecture se propage : elle n'ouvre jamais la passerelle.
  const gate=(await db.collection('operations_control').doc('account_deletion').get()).data();
  if(gate?.enabled!==true || gate.inventoryVersion!==1)throw new HttpsError('failed-precondition','ACCOUNT_DELETION_NOT_ENABLED',{reason:'ACCOUNT_DELETION_NOT_ENABLED'});
  await checkRateLimit(uid,'account_deletion_request',RATE_MAX,RATE_WINDOW_S);
  const recent=Number.isFinite(request.auth.token?.auth_time) && clock()/1000-request.auth.token.auth_time>=0 && clock()/1000-request.auth.token.auth_time<=300;
  const ref=jobRef(uid);
  let repeated=false;
  await db.runTransaction(async tx=>{
   repeated=false;
   const old=await tx.get(ref);
   if((await tx.get(db.collection('admins').doc(uid))).exists)throw new HttpsError('failed-precondition','ADMIN_ACCOUNT_MANUAL_PROCESS');
   const identity=await readDeletionIdentity(tx,db,uid,role);
   if(!identity)throw new HttpsError('permission-denied','Identite du profil non etablie; verification support necessaire');
   const profileRef=identity.ref;
   if(old.exists){
    const o=old.data();
    if(o.role!==role)throw new HttpsError('failed-precondition','Demande existante pour un autre role');
    if(o.state==='completed'){repeated=true;return;}
    const count=o.requestCount||0;
    if(count>=MAX_REQUESTS)throw new HttpsError('resource-exhausted','ACCOUNT_DELETION_REQUEST_LIMIT');
    // Une demande qui apporte une information nouvelle (réauthentification récente, consentement) n'est jamais absorbée.
    const adds=recent&&(!o.consentVerified||(request.data.allProfilesConsent===true&&o.allProfilesConsent!==true));
    if(!adds&&typeof o.lastRequestAt==='number'&&clock()>=o.lastRequestAt&&clock()-o.lastRequestAt<REPEAT_WINDOW_MS){repeated=true;return;}
    tx.update(ref,{requestCount:count+1,lastRequestAt:clock()});
    if(!old.data().consentVerified && recent)tx.update(ref,{consentVerified:true,state:'pending',reason:null,nextAttemptAt:clock()});
    if(recent&&request.data.allProfilesConsent===true)tx.update(ref,{allProfilesConsent:true,nextAttemptAt:clock()});
    if(role==='livreur' && (recent || old.data().consentVerified))tx.update(profileRef,{deletionRequested:true});
    return;
   }
   if(role==='livreur' && recent)tx.update(profileRef,{deletionRequested:true});
   tx.create(ref,{uid,role,profilePath:identity.profilePath,...(identity.businessPath?{businessPath:identity.businessPath}:{}),recoveryHash:digest(token),state:'pending',reason:recent?null:'reauthentication_required',
    consentVerified:recent,allProfilesConsent:recent&&request.data.allProfilesConsent===true,requestedAt:stamp(),reviewAfter:clock()+72*60*60*1000,nextAttemptAt:recent?clock():null,
    requestCount:1,lastRequestAt:clock(),attempts:0});
  });
  await auditInfo({userId:uid,userType:role,action:repeated?'account_deletion_request_repeated':'account_deletion_requested',targetId:uid,metadata:{role,reauthenticated:recent}});
  if(repeated)return publicState((await ref.get()).data());
  return process(uid);
 }
 async function status(request){
  const uid=request.data?.uid,token=request.data?.recoveryToken;
  if(typeof uid!=='string'||!uid||uid.includes('/')||!validToken(token))throw new HttpsError('invalid-argument','Demande invalide');
  const snap=await jobRef(uid).get(),j=snap.data();
  const hash=digest(token);
  if(!j || typeof j.recoveryHash!=='string'||j.recoveryHash.length!==hash.length ||
     !timingSafeEqual(Buffer.from(j.recoveryHash),Buffer.from(hash)))throw new HttpsError('permission-denied','Suivi indisponible');
  // Limite appliquée APRÈS la vérification du jeton : un tiers ne peut pas verrouiller le suivi d'un autre compte.
  if(typeof checkRateLimit==='function')await checkRateLimit(uid,'account_deletion_status',30,600);
  // Recovery capability allows only reading this minimal status, never starting deletion.
  return publicState(j);
 }
 async function drain(){
  const jobs=await db.collection('account_deletions').where('nextAttemptAt','<=',clock()).limit(20).get();
  for(const doc of jobs.docs){try{await process(doc.id);}catch(_){/* remains due; no false completion */}}
 }
 return {request,status,process,drain};
}
module.exports={buildAccountDeletion,assertAccountEnabled,QUIET_MS,MAX_ATTEMPTS,MAX_REQUESTS,REPEAT_WINDOW_MS};
