'use strict';

// Provider boundary: never log request/body/error objects (they can contain a PIN).
class SmsProvider {
  get available() { return false; }
  async send() { throw new Error('SMS_UNAVAILABLE'); }
}

class MockSmsProvider extends SmsProvider {
  constructor({ outcome = 'simulated', inspect } = {}) {
    super();
    this.outcome = outcome;
    this.inspect = inspect; // Tests only; no message retained by this adapter.
    this.calls = 0;
  }
  get available() { return true; }
  async send(message) {
    this.calls++;
    if (this.inspect) this.inspect(message);
    if (this.outcome === 'unknown') throw new Error('SIMULATED_TIMEOUT');
    return { status: this.outcome };
  }
}

function configuredSmsProvider() {
  // No real API has been selected/validated. Even a misconfigured production
  // environment cannot send a real SMS or mistake a simulation for acceptance.
  if (process.env.FUNCTIONS_EMULATOR === 'true' && process.env.DELIVERY_SMS_PROVIDER === 'mock') {
    return new MockSmsProvider();
  }
  return new SmsProvider();
}

function normalizeCiMobile(value) {
  if (typeof value !== 'string' || value.length > 40 || !/^[+\d\s().-]+$/.test(value)) {
    throw new Error('INVALID_PHONE');
  }
  let number = value.replace(/[\s().-]/g, '');
  if (number.startsWith('00225')) number = `+225${number.slice(5)}`;
  if (/^0[157]\d{8}$/.test(number)) number = `+225${number}`;
  if (!/^\+2250[157]\d{8}$/.test(number)) throw new Error('INVALID_PHONE');
  return number;
}

function receiptSms(pin) {
  if (!/^\d{6}$/.test(pin)) throw new Error('INVALID_PIN');
  // ASCII / GSM-7 basic alphabet, <160 characters = one segment.
  return `AZ Express : code de reception ${pin}, valable 15 min. Donnez ce code au livreur uniquement apres reception du colis.`;
}

module.exports = { SmsProvider, MockSmsProvider, configuredSmsProvider, normalizeCiMobile, receiptSms };
