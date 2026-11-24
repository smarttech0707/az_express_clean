## Architecture cible

```
Flutter UI → Application Layer (providers/state) → Services → Cloud Functions → Firestore/Storage
```

Note honnête sur l'état réel du code : une partie des écritures (ex. création de commandes livraison/courses/restaurant/pharmacie) se fait aujourd'hui directement depuis le client Flutter vers Firestore, sans Cloud Function intermédiaire — c'est l'état hérité, pas la cible. Toute logique métier **nouvelle** ou **sensible** (paiement, wallet, actions déclenchées par AZ IA, tout ce qui touche à la confiance/fraude) doit passer par une Cloud Function, jamais par une écriture Firestore directe côté client.

Il n'y a pas de produit "API Gateway" séparé devant les Cloud Functions — les Cloud Functions callable/HTTP **sont** la couche API. Ne pas introduire de gateway supplémentaire (Cloud Endpoints, Apigee, etc.) sans besoin concret : ça ajouterait une couche opérationnelle sans bénéfice tant que le trafic reste dans cette gamme.

