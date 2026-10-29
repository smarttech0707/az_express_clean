'use strict';
const {ROLE_COLLECTIONS,readDeletionIdentity}=require('./accountDeletionIdentity');
const TERMINAL=new Set(['delivered','cancelled','expired','completed','refunded','failed_refunded','failed','rejected','closed']);
const FINANCIAL=['wallet','walletBalance','balance','debt','pendingBalance','reservedBalance','pendingWithdrawal','commissionDebt'];
// Bounded, fail-closed inspection: no status, balance or responsibility is guessed.
async function readDeletionScope(tx,db,uid){
 if((await tx.get(db.collection('admins').doc(uid))).exists)return {reason:'admin_account_manual_review'};
 const profiles=[],businesses=new Map(),related=new Map();
 for(const role of Object.keys(ROLE_COLLECTIONS)){
  const identity=await readDeletionIdentity(tx,db,uid,role);
  if(!identity){
   const raw=await tx.get(db.collection(role==='pharmacie'?'pharmacy_owners':ROLE_COLLECTIONS[role]).doc(uid));
   if(raw.exists)return {reason:'identity_scope_inconsistent'};
  }
  if(identity){profiles.push({...identity,role});if(identity.businessPath){
   const business=await tx.get(db.doc(identity.businessPath));businesses.set(business.ref.path,business);
  }}
 }
 if(!profiles.length)return {reason:'profile_missing'};
 const businessesToFreeze=[];
 for(const p of profiles.filter(p=>p.businessPath)){
  const isPharmacy=p.role==='pharmacie';
  const owners=await tx.get(db.collection(isPharmacy?'pharmacy_owners':'restaurant_owners').where(isPharmacy?'pharmacyId':'restaurantId','==',p.businessPath.split('/')[1]).limit(201));
  if(owners.size>=201)return {profiles,reason:'business_owners_review_required'};
  if(!owners.docs.some(doc=>doc.id!==uid&&doc.data().isDeleted!==true&&doc.data().deletionRequested!==true))businessesToFreeze.push(db.doc(p.businessPath));
 }
 const result={profiles,businesses:[...businesses.values()],businessesToFreeze,related:[]};
 for(const p of profiles){
  const data=p.profile;
  if(['client','livreur','seller','boulangerie'].includes(p.role)&&!Object.hasOwn(data,'wallet'))return {...result,reason:'balance_regularization_required'};
  if(p.role==='ekbine_agent'&&!Object.hasOwn(data,'walletBalance'))return {...result,reason:'balance_regularization_required'};
  for(const field of FINANCIAL)if(data[field]!=null&&(!Number.isSafeInteger(data[field])||data[field]!==0))return {...result,reason:'balance_regularization_required'};
  if(data.isOnDelivery===true||data.currentOrderId||data.pendingOrderId)return {...result,reason:'active_mission_or_reference'};
 }
 for(const b of businesses.values()){
  for(const field of FINANCIAL){const value=b.data()[field];if(value!=null&&(!Number.isSafeInteger(value)||value!==0))return {...result,reason:'business_financial_review_required'};}
 }
 const queries=new Map();
 const add=(collection,field,id,kind='operation')=>queries.set([collection,field,id].join('|'),{collection,field,id,kind});
 for(const p of profiles){
  const role=p.role,personalId=p.ref.id;
  const field=role==='client'?'clientId':role==='livreur'?'driverId':role==='ekbine_agent'||role==='real_estate_agent'?'agentId':role==='fleet_owner'?'ownerId':'sellerId';
  const id=p.businessPath?p.businessPath.split('/')[1]:personalId;
  for(const collection of ['orders','boutique_orders','blanchisserie_orders','eau_boissons_orders','ekbine_orders'])add(collection,field,id);
  if(role==='restaurant')add('orders','restaurantId',id);
  if(role==='pharmacie')add('orders','pharmacieId',id);
  if(role==='boulangerie')add('orders','boulangerieId',id);
  if(role==='fleet_owner')add('livreurs','ownerId',id,'responsibility');
  if(role==='real_estate_agent'){add('real_estate_visit_requests','agentId',id);add('real_estate_listings','agentId',id,'listing');}
  if(role==='seller'){add('marketplace_products','sellerId',id,'listing');add('boutique_products','sellerId',id,'listing');}
  add('withdrawal_requests','userId',personalId);add('wallet_transactions','userId',personalId);
 }
 for(const q of queries.values()){
  const snap=await tx.get(db.collection(q.collection).where(q.field,'==',q.id).limit(201));
  if(snap.size>=201)return {...result,reason:'history_requires_manual_review'};
  for(const doc of snap.docs){
   const d=doc.data();
   if(q.kind==='responsibility')return {...result,reason:'responsibilities_transfer_required'};
   if(q.kind==='listing'){
    if(!['hidden','archived','inactive','deleted','sold'].includes(d.status))return {...result,reason:'active_listing_review_required'};
   }else if(!TERMINAL.has(d.status)||d.refundPending===true||d.needsReview===true||d.paymentStatus==='pending')return {...result,reason:'active_or_unresolved_operation'};
   related.set(doc.ref.path,doc);if(related.size>=200)return {...result,reason:'history_requires_manual_review'};
  }
 }
 return {...result,related:[...related.values()]};
}
module.exports={readDeletionScope,FINANCIAL};
