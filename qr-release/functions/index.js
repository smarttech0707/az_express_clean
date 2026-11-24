'use strict';
const {onCall,HttpsError}=require('firebase-functions/v2/https');
const {onDocumentWritten}=require('firebase-functions/v2/firestore');
const admin=require('firebase-admin');
const {buildPartnerQr,available,COLLECTIONS}=require('./partnerQr');
admin.initializeApp();
const db=admin.firestore();
const api=buildPartnerQr({db,auth:admin.auth(),HttpsError});
const region='europe-west1';
exports.getPartnerQr=onCall({region,maxInstances:2},api.manage);
exports.resolvePartnerQr=onCall({region,maxInstances:2},api.resolve);
exports.listPartnerQrEstablishments=onCall({region,maxInstances:2},api.list);
exports.setPartnerQrManager=onCall({region,maxInstances:1},async request=>{
  // Same pre-handler quarantine check as the original wrapper; no deletion initialization.
  if(request.auth?.uid && (await db.collection('account_tombstones').doc(request.auth.uid).get()).exists)
    throw new HttpsError('permission-denied','ACCOUNT_DELETION_IN_PROGRESS');
  return api.grant(request);
});
for(const [kind,collection] of Object.entries(COLLECTIONS)){
 exports['syncPartnerQr_'+kind]=onDocumentWritten({document:collection+'/{id}',region,maxInstances:1,retry:true},event=>{
  const before=event.data?.before.data(),after=event.data?.after.data();
  if(!available(after)||available(before))return;
  return api.sync(kind,event.params.id);
 });
}
