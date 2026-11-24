'use strict';
(async()=>{
 const message=document.getElementById('message'),name=document.getElementById('name'),kind=document.getElementById('kind');
 const match=location.pathname.match(/^\/partenaire\/([-a-zA-Z0-9]{20,80})\/?$/);
 if(!match){message.textContent='QR code invalide.';return;}
 const controller=new AbortController();const timer=setTimeout(()=>controller.abort(),15000);
 try{
  const response=await fetch('https://europe-west1-az-express-b0469.cloudfunctions.net/resolvePartnerQr',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({data:{token:match[1]}}),signal:controller.signal});
  if(!response.ok)throw Error('lookup failed');const body=await response.json();const data=body.result??body.data;
  if(!data||typeof data.available!=='boolean')throw Error('invalid response');
  if(!data.available){message.textContent='Cet établissement est indisponible.';return;}
  const types={restaurant:'Restaurant',seller:'Boutique',pharmacie:'Pharmacie',boulangerie:'Boulangerie'};
  if(typeof data.name!=='string'||!Object.hasOwn(types,data.kind))throw Error('invalid establishment');
  name.textContent=data.name;kind.textContent=types[data.kind];message.textContent='Fiche de l’établissement';
 }catch(_){message.textContent='Impossible de charger la fiche. Veuillez réessayer.';}finally{clearTimeout(timer);}
})();
