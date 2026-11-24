# Gemini lot 2: local canonical conversation

No deployment or real provider/payment request is part of this change.

## Routing

`azIaChat -> aiGateway -> AIProviderService -> compatible provider` uses canonical
text/image/tool_call/tool_result history. Gemini and Claude implement this
capability. OpenAI's existing adapter and tests remain available to existing
callers, but it is excluded from this canonical loop until its native
continuation protocol is integrated and tested. Its tools flag alone is not
sufficient to opt into this loop.

Example configuration for a later, separately authorized change to settings/ai:

```json
{
  "defaultProvider": "gemini",
  "allowedProviders": ["gemini", "claude"],
  "fallbackEnabled": true,
  "fallbackProviders": ["claude"]
}
```

An omitted toolProvider inherits the default provider. An explicit legacy
toolProvider is still a deliberate override: toolProvider=claude keeps tool
turns on Claude even if defaultProvider=gemini. No production setting was read
or changed. The legacy provider/fallbackEnabled fields remain supported.

Gemini resolves GEMINI_MODEL (target: gemini-3.8-flash), Claude resolves
CLAUDE_MODEL then its existing default, OpenAI keeps OPENAI_MODEL. Optional
models[provider] values are provider-specific. A legacy preferredModel or an
explicit per-call model is never passed to a different fallback provider.
No .env file was read or modified in this lot.

## Replay boundary

Each authenticated chat invocation creates its own execution ledger. The
canonicalCallId is a SHA-256 of the tool name and recursively sorted JSON
arguments. Native provider IDs remain intact for protocol pairing. Repeated
logical calls, including a new native ID on fallback, reuse the same promise
and result. Errors are also retained: a partially effective handler is not
automatically retried. Execution remains sequential.

Identical name/arguments mean one action per invocation. An intentional second
action requires another user turn. This is NOT distributed idempotence: a new
request, process restart or differently expressed arguments has a new scope.
Existing financial transactions, confirmations and webhook checks still apply.

The loop retains six tool turns and one text-only closing turn. Tool requests
returned during closing are never executed.

## Native continuation

Claude converts canonical history at its boundary and owns its cache hints.
Gemini keeps full native response parts, including thought signatures, in a
provider-local WeakMap keyed by canonical content arrays. No native signature
or thought content is exposed to the central loop or Flutter. Cross-model
function history uses Google's documented transfer marker only when no native
Gemini continuation exists; received Gemini signatures are reused unchanged.

Reference: https://ai.google.dev/gemini-api/docs/generate-content/thought-signatures
(FAQ on transfer from a different model). This behavior is tested with mocks;
real service acceptance is not certified by local tests.

## Validation

From the repository root, run:

```powershell
node functions/scripts/testAziaOffline.js
```

Optional arguments select filenames in functions/test. Each suite runs in an
isolated process with a 60-second external timeout. The preloaded guard blocks
network transports, including inherited subprocesses. Credentials from the
parent environment are removed; tests provide only dummy values. No emulator
or production database is used. Nonzero exits, failed assertions and cancelled
tests remain failures.

aziaCanonicalE2E.test.js exercises the actual callable, gateway, adapters,
registry and confirmations against in-memory services. It covers both fallback
directions, repeated native IDs/arguments, wallet reads, unique recharge and
order pending actions, refunds after confirmation, images, policy and turn caps.

## Remaining production limits

The existing create_shopping_order post-confirm dispatch fails with
`pickupCityId manquant`. Tests explicitly assert this observed limitation;
they do not claim dispatch succeeded. Its financial confirmation commits once,
and replay is refused. Dispatch code is outside this provider integration.

The ledger does not replace persistent request idempotency. No actual Gemini,
Claude, OpenAI or FeexPay call was made. Production rollout remains unapproved.
