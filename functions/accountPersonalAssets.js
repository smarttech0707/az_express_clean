'use strict';
// UID-scoped personal media only. Restaurant/pharmacy/bakery logos, catalogues,
// order proofs and shared establishment files are deliberately not in this list.
const PERSONAL_PREFIXES=Object.freeze({client:['client_photos'],livreur:['driver_photos','driver_id_photos','driver_selfies'],
 seller:['seller_photos'],ekbine_agent:['ekbine_agent_photos'],real_estate_agent:['real_estate_agent_photos'],
 fleet_owner:['fleet_photos','fleet_selfies','fleet_id_photos']});
// Le selfie d'acceptation est rangé par COMMANDE (acceptance_selfies/<commande>/<uid>.jpg), pas par UID : un
// préfixe ne suffit pas. On balaie le dossier par pages et on ne supprime que les fichiers nommés <uid>.jpg.
// Si le balayage n'est pas terminé, on lève une erreur : la suppression reste en reprise, jamais « terminée ».
const SELFIE_PAGE=1000,SELFIE_MAX_PAGES=200;
async function eraseAcceptanceSelfies(bucket,uid){
 let pageToken;
 for(let page=0;page<SELFIE_MAX_PAGES;page++){
  const [files,next]=await bucket.getFiles({prefix:'acceptance_selfies/',maxResults:SELFIE_PAGE,autoPaginate:false,...(pageToken?{pageToken}:{})});
  for(const file of files)if(file.name.endsWith('/'+uid+'.jpg')&&file.name.split('/').length===3)await file.delete({ignoreNotFound:true});
  pageToken=next&&next.pageToken;
  if(!pageToken)return;
 }
 throw Error('ACCEPTANCE_SELFIE_SCAN_INCOMPLETE');
}
async function erasePersonalAssets(bucket,uid,role){
 if(typeof uid!=='string'||!uid||uid.includes('/'))throw Error('INVALID_ASSET_UID');
 for(const prefix of PERSONAL_PREFIXES[role]||[])await bucket.deleteFiles({prefix:`${prefix}/${uid}/`});
 if(role==='livreur')await eraseAcceptanceSelfies(bucket,uid);
}
module.exports={PERSONAL_PREFIXES,erasePersonalAssets};
