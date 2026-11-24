'use strict';

// Promise.all rejects before a still-running writer finishes. A test's next
// beforeEach could then delete fixtures while that writer is still committing.
// Drain every operation and preserve every rejection; this never retries.
async function settleConcurrent(operations) {
  const results = await Promise.allSettled(operations);
  const errors = results.filter(result => result.status === 'rejected').map(result => result.reason);
  if (errors.length) throw new AggregateError(errors, 'Concurrent operations failed');
  return results.map(result => result.value);
}

module.exports = { settleConcurrent };
