'use strict';
const ROLE_COLLECTIONS=Object.freeze({client:'clients',livreur:'livreurs',seller:'sellers',restaurant:'restaurant_owners',
 pharmacie:'pharmacies',boulangerie:'boulangeries',ekbine_agent:'ekbine_agents',real_estate_agent:'real_estate_agents',fleet_owner:'fleet_owners'});
async function readDeletionIdentity(tx,db,uid,role){
 if(!Object.hasOwn(ROLE_COLLECTIONS,role))return null;
 // Only an admin-nominated binding accepted by this permanent Auth user.
 if(role==='pharmacie'){
  const ref=db.collection('pharmacy_owners').doc(uid),owner=await tx.get(ref);
  const id=owner.data()?.pharmacyId;
  if(!owner.exists||owner.data().uid!==uid||typeof id!=='string'||!id||id.includes('/'))return null;
  const pharmacy=await tx.get(db.collection('pharmacies').doc(id));
  if(!pharmacy.exists)return null;
  return {ref,profile:owner.data(),profilePath:ref.path,businessPath:pharmacy.ref.path};
 }
 const ref=db.collection(ROLE_COLLECTIONS[role]).doc(uid),snap=await tx.get(ref);
 if(!snap.exists)return null;
 if(role==='restaurant'){
  const id=snap.data().restaurantId;
  if(typeof id!=='string'||!id||id.includes('/'))return null;
  const business=await tx.get(db.collection('restaurants').doc(id));
  if(!business.exists)return null;
  return {ref,profile:snap.data(),profilePath:ref.path,businessPath:business.ref.path};
 }
 return {ref,profile:snap.data(),profilePath:ref.path};
}
module.exports={ROLE_COLLECTIONS,readDeletionIdentity};
