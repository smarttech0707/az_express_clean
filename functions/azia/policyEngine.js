'use strict';

// The model can request an action, never authorize it. Existing handlers and
// pendingActions.js remain the final enforcement points for all business rules.
function createPolicyEngine({ tools }) {
  const byName = new Map(tools.map((tool) => [tool.name, tool]));

  function allowedToolNames(config = {}) {
    const configured = config.allowedTools;
    if (!Array.isArray(configured) || configured.length === 0) return new Set(byName.keys());
    return new Set(configured.filter((name) => byName.has(name)));
  }

  function getToolSchemas(config = {}) {
    const allowed = allowedToolNames(config);
    return tools.filter((tool) => allowed.has(tool.name)).map((tool) => ({
      name: tool.name,
      description: tool.description,
      input_schema: tool.input_schema,
    }));
  }

  function canExecute(name, config = {}) {
    return allowedToolNames(config).has(name) && byName.has(name);
  }

  function requiresConfirmation(name) {
    // Do not duplicate or reinterpret financial policy here. A confirmHandler
    // is the established server-side source of truth in the current registry.
    return typeof byName.get(name)?.confirmHandler === 'function';
  }

  return { getToolSchemas, canExecute, requiresConfirmation };
}

module.exports = { createPolicyEngine };
