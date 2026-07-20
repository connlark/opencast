// Mints throwaway Apple-shaped P-256 chains for the workerd tests (offline
// verification: no AIA/OCSP). Requires openssl (macOS dev machines: the
// Homebrew OpenSSL 3.x used across this repo's server tests). Output lands
// in test/fixtures/generated/ (gitignored); fixtures are re-minted when
// older than a day so date-window checks stay valid.

import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const fixturesDir = path.dirname(fileURLToPath(import.meta.url));
const generatedDir = path.join(fixturesDir, 'generated');
const outputPath = path.join(generatedDir, 'fixtures.json');

const OPENSSL = existsSync('/opt/homebrew/bin/openssl') ? '/opt/homebrew/bin/openssl' : 'openssl';

function openssl(args, options = {}) {
  return execFileSync(OPENSSL, args, { cwd: generatedDir, ...options });
}

function writeConfig(name, contents) {
  writeFileSync(path.join(generatedDir, name), contents);
}

function derBase64(pemFile) {
  const pem = readFileSync(path.join(generatedDir, pemFile), 'utf8');
  return pem
    .replace(/-----BEGIN CERTIFICATE-----/, '')
    .replace(/-----END CERTIFICATE-----/, '')
    .replace(/\s+/g, '');
}

function mintChain(prefix, commonNamePrefix) {
  for (const name of ['root', 'int', 'leaf']) {
    openssl(['ecparam', '-name', 'prime256v1', '-genkey', '-noout', '-out', `${prefix}-${name}.key`]);
  }

  writeConfig(
    `${prefix}-root.cnf`,
    `[req]\ndistinguished_name = dn\nprompt = no\n[dn]\nCN = ${commonNamePrefix} Root CA\nO = PurchaseWorker Tests\n[v3_ca]\nbasicConstraints = critical,CA:TRUE\nkeyUsage = critical,keyCertSign,cRLSign\nsubjectKeyIdentifier = hash\n`,
  );
  openssl([
    'req', '-new', '-x509', '-key', `${prefix}-root.key`, '-out', `${prefix}-root.crt`,
    '-days', '30', '-config', `${prefix}-root.cnf`, '-extensions', 'v3_ca', '-set_serial', '0x0999',
  ]);

  writeConfig(
    `${prefix}-int.cnf`,
    `[req]\ndistinguished_name = dn\nprompt = no\n[dn]\nCN = ${commonNamePrefix} Intermediate CA\nO = PurchaseWorker Tests\n[v3_int]\nbasicConstraints = critical,CA:TRUE\nkeyUsage = critical,keyCertSign,cRLSign\nsubjectKeyIdentifier = hash\nauthorityKeyIdentifier = keyid:always\n1.2.840.113635.100.6.2.1 = ASN1:NULL\n`,
  );
  openssl(['req', '-new', '-key', `${prefix}-int.key`, '-out', `${prefix}-int.csr`, '-config', `${prefix}-int.cnf`]);
  openssl([
    'x509', '-req', '-in', `${prefix}-int.csr`, '-CA', `${prefix}-root.crt`, '-CAkey', `${prefix}-root.key`,
    '-out', `${prefix}-int.crt`, '-days', '30', '-extfile', `${prefix}-int.cnf`, '-extensions', 'v3_int',
    '-set_serial', '0x2001',
  ]);

  writeConfig(
    `${prefix}-leaf.cnf`,
    `[req]\ndistinguished_name = dn\nprompt = no\n[dn]\nCN = ${commonNamePrefix} Leaf\nO = PurchaseWorker Tests\n[v3_leaf]\nbasicConstraints = critical,CA:FALSE\nkeyUsage = critical,digitalSignature\nsubjectKeyIdentifier = hash\nauthorityKeyIdentifier = keyid:always\n1.2.840.113635.100.6.11.1 = ASN1:NULL\n`,
  );
  openssl(['req', '-new', '-key', `${prefix}-leaf.key`, '-out', `${prefix}-leaf.csr`, '-config', `${prefix}-leaf.cnf`]);
  openssl([
    'x509', '-req', '-in', `${prefix}-leaf.csr`, '-CA', `${prefix}-int.crt`, '-CAkey', `${prefix}-int.key`,
    '-out', `${prefix}-leaf.crt`, '-days', '30', '-extfile', `${prefix}-leaf.cnf`, '-extensions', 'v3_leaf',
    '-set_serial', '0x1001',
  ]);

  return {
    rootDerBase64: derBase64(`${prefix}-root.crt`),
    x5c: [derBase64(`${prefix}-leaf.crt`), derBase64(`${prefix}-int.crt`), derBase64(`${prefix}-root.crt`)],
    leafKeyPem: readFileSync(path.join(generatedDir, `${prefix}-leaf.key`), 'utf8'),
  };
}

const FIXTURE_VERSION = 2;

export function mintFixtures() {
  if (existsSync(outputPath)) {
    const ageMs = Date.now() - statSync(outputPath).mtimeMs;
    if (ageMs < 24 * 3600 * 1000) {
      const existing = JSON.parse(readFileSync(outputPath, 'utf8'));
      if (existing.version === FIXTURE_VERSION) {
        return existing;
      }
    }
  }
  rmSync(generatedDir, { recursive: true, force: true });
  mkdirSync(generatedDir, { recursive: true });

  const trusted = mintChain('trusted', 'PW Test');
  const rogue = mintChain('rogue', 'PW Rogue');
  // Throwaway ES256 key standing in for the Apple In-App Purchase API key
  // (only ever used against a mocked Apple host).
  openssl(['ecparam', '-name', 'prime256v1', '-genkey', '-noout', '-out', 'api-key.pem']);
  openssl(['pkcs8', '-topk8', '-nocrypt', '-in', 'api-key.pem', '-out', 'api-key-pkcs8.pem']);

  const fixtures = {
    version: FIXTURE_VERSION,
    mintedAtMs: Date.now(),
    trusted,
    rogue,
    apiKeyPem: readFileSync(path.join(generatedDir, 'api-key-pkcs8.pem'), 'utf8'),
  };
  writeFileSync(outputPath, JSON.stringify(fixtures, null, 2));
  return fixtures;
}
