'use strict';
// Preloaded in every test process, including subprocesses through NODE_OPTIONS.
// No environment file is loaded. Tests must inject fake transports/services.
const deny = () => { throw new Error('NETWORK_FORBIDDEN_OFFLINE_TEST'); };
for (const name of ['http', 'https']) {
  require(name).request = deny;
  require(name).get = deny;
}
require('net').Socket.prototype.connect = deny;
require('tls').connect = deny;
global.fetch = async () => deny();
