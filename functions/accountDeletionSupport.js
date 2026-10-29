'use strict';
const {requireSuperAdmin}=require('./adminGuards');

// No support action can change consent, money, identity bindings or completion.
function buildAccountDeletionSupport({db,admin,HttpsError,process,clock=Date.now}) {
 const validId=x=>typeof x==='string' && x.length>0 && x.length<=128 && !x.includes('/');
 return async request=>{
  await requireSuperAdmin({request,db});
  const {action,kind='verified',id,cursor,resolution}=request.data||{};
  if(!['verified','manual'].includes(kind))throw new HttpsError('invalid-argument','File invalide');
  const collection=db.collection(kind==='verified'?'account_deletions':'account_deletion_requests');
  if(action==='list'){
   if(cursor!=null&&!validId(cursor))throw new HttpsError('invalid-argument','Curseur invalide');
   let query=collection.orderBy(admin.firestore.FieldPath.documentId()).limit(25);
   if(cursor)query=query.startAfter(cursor);
   const page=await query.get();
   return {items:page.docs.map(doc=>{const d=doc.data();return {id:doc.id,role:d.role||'unknown',state:d.state||d.status||'pending',reason:d.reason||null,
    supportState:d.supportState||'unassigned',reviewAfter:d.reviewAfter||null,overdue:typeof d.reviewAfter==='number'&&d.reviewAfter<clock()&&d.state!=='completed'};}),
    cursor:page.size===25?page.docs[page.docs.length-1].id:null};
  }
  if(!validId(id)||!['claim','retry'].includes(action))throw new HttpsError('invalid-argument','Action invalide');
  if(action==='retry'&&(kind!=='verified'||!['mission_resolved','balance_reviewed','identity_reviewed','technical_retry'].includes(resolution)))
   throw new HttpsError('invalid-argument','Reprise invalide');
  const ref=collection.doc(id),audit=ref.collection('support_events').doc();
  await db.runTransaction(async tx=>{
   const snap=await tx.get(ref);
   if(!snap.exists)throw new HttpsError('not-found','Demande absente');
   if(snap.data().state==='completed')throw new HttpsError('failed-precondition','Demande terminee');
   const patch={supportOwner:request.auth.uid,supportState:'in_review',supportUpdatedAt:admin.firestore.FieldValue.serverTimestamp(),reviewAfter:clock()+24*60*60*1000};
   if(action==='retry')patch.nextAttemptAt=clock();
   tx.update(ref,patch);
   tx.create(audit,{actorUid:request.auth.uid,action,resolution:resolution||null,createdAt:admin.firestore.FieldValue.serverTimestamp()});
  });
  if(action==='retry')return {result:await process(id)};
  return {recorded:true};
 };
}
module.exports={buildAccountDeletionSupport};
