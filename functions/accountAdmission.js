'use strict';
async function assertNewAccountActivity(tx,db,HttpsError,uid,partners=[]){
 if(typeof uid!=='string'||!uid||uid.includes('/'))throw new HttpsError('failed-precondition','Identite de commande invalide');
 // Re-read the durable marker inside the financial transaction. A callable's
 // earlier authentication check cannot protect against deletion racing it.
 const tombstone=await tx.get(db.collection('account_tombstones').doc(uid));
 if(tombstone.exists)throw new HttpsError('failed-precondition','Compte supprime ou en cours de suppression');
 for(const [collection,id] of [['clients',uid],...partners]){
  if(typeof id!=='string'||!id||id.includes('/'))throw new HttpsError('failed-precondition','Identite de commande invalide');
  const snap=await tx.get(db.collection(collection).doc(id));
  if(snap.exists&&(snap.data().deletionRequested===true||snap.data().isDeleted===true))throw new HttpsError('failed-precondition','Compte en cours de suppression; nouvelles operations suspendues');
 }
}
module.exports={assertNewAccountActivity};
