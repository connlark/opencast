// Cross-language contract oracle; no production ingress imports this module.
import { hash } from './fixtures.mjs';

export function H(parts) {
  if (!Array.isArray(parts) || parts.some(part => typeof part !== 'string' || !part.isWellFormed())) throw Error('invalid_identity_parts');
  return hash(JSON.stringify(parts));
}

export function canonicalJSON(value) {
  if (value === null || typeof value === 'boolean') return JSON.stringify(value);
  if (typeof value === 'string' && value.isWellFormed()) return JSON.stringify(value);
  if (typeof value === 'number' && Number.isSafeInteger(value)) return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(canonicalJSON).join(',')}]`;
  if (value && Object.getPrototypeOf(value) === Object.prototype) {
    const keys = Object.keys(value).sort();
    if (keys.some(key => !/^[a-z_]+$/.test(key))) throw Error('invalid_key');
    return `{${keys.map(key => `${JSON.stringify(key)}:${canonicalJSON(value[key])}`).join(',')}}`;
  }
  throw Error('invalid_canonical_value');
}

export const payloadDigest = envelope => hash(canonicalJSON(envelope));
