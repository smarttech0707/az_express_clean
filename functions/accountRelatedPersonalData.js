'use strict';

// A multirole account can be seller on one order and customer on another.
// Never erase the other participant's contact details on the basis of roles alone.
function relatedPersonalPatch(data, uid, roles, deleteValue) {
  const fields = [];
  if (roles.has('client') && data.clientId === uid) {
    fields.push('clientName', 'clientPhone', 'clientEmail', 'recipientName',
      'recipientPhone', 'pickupContactName', 'pickupContactPhone',
      'deliveryAddress', 'pickupAddress', 'latitude', 'longitude',
      'destLat', 'destLng', 'pickupLat', 'pickupLng', 'voiceMessage');
  }
  if (roles.has('livreur') && data.driverId === uid) {
    fields.push('driverName', 'driverPhone', 'driverEmail', 'driverPhotoUrl',
      'driverAcceptanceSelfie');
  }
  return Object.fromEntries(fields.filter(field => Object.hasOwn(data, field))
    .map(field => [field, deleteValue]));
}

module.exports = { relatedPersonalPatch };
