'use strict';
const { createHash } = require('node:crypto');

function stableJson(value) {
  if (Array.isArray(value)) return `[${value.map(stableJson).join(',')}]`;
  if (value && typeof value === 'object') {
    return `{${Object.keys(value).sort().map(key => `${JSON.stringify(key)}:${stableJson(value[key])}`).join(',')}}`;
  }
  return JSON.stringify(value);
}

// One ledger per authenticated chat invocation, never shared across users or
// requests. Identical name/arguments mean one logical action in this sequence,
// even when a fallback assigns a different native ID. Intentional repetition
// requires a new user turn. Transactional business protections remain required.
function createToolExecutionLedger() {
  const results = new Map();
  function identify(call) {
    return `call_${createHash('sha256').update(stableJson([call.name, call.input || {}])).digest('hex')}`;
  }
  async function execute(call, run) {
    if (call.argumentsError) throw new Error('Invalid tool arguments');
    const canonicalCallId = identify(call);
    if (!results.has(canonicalCallId)) {
      // Store the promise before execution, including rejection: no automatic
      // retry of a handler whose effects may already have occurred.
      results.set(canonicalCallId, Promise.resolve().then(run));
    }
    return { canonicalCallId, result: await results.get(canonicalCallId) };
  }
  return { identify, execute };
}
module.exports = { createToolExecutionLedger };
