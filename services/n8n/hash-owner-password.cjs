'use strict';
/*
 * Prints a bcrypt hash of N8N_OWNER_PASSWORD for N8N_INSTANCE_OWNER_PASSWORD_HASH.
 *
 * n8n (2.x) creates/updates the owner from N8N_INSTANCE_OWNER_* variables when
 * N8N_INSTANCE_OWNER_MANAGED_BY_ENV=true, but it only accepts a pre-hashed password
 * (/^\$2[aby]\$\d{2}\$[./A-Za-z0-9]{53}$/). This uses the bcryptjs copy that ships with
 * n8n, i.e. the library n8n verifies logins with, at n8n's own cost factor.
 *
 *   node hash-owner-password.cjs              hash N8N_OWNER_PASSWORD, print the hash
 *   node hash-owner-password.cjs --self-test  check that hashing works (Docker build)
 */
const N8N_DIR = '/usr/local/lib/node_modules/n8n';
const ROUNDS = 10; // packages/cli/src/services/password.utility.ts (SALT_ROUNDS)
const HASH_PATTERN = /^\$2[aby]\$\d{2}\$[./A-Za-z0-9]{53}$/; // owner.instance-settings-loader.ts
const MIN_LENGTH = 8;
const MAX_BYTES = 72; // bcrypt ignores everything after 72 bytes
const SELF_TEST_PASSWORD = 'Railway-self-test-1';

function loadBcrypt() {
  try {
    return require(require.resolve('bcryptjs', { paths: [N8N_DIR] }));
  } catch (error) {
    throw new Error(`bcryptjs not found next to n8n (${N8N_DIR}): ${error.message}`);
  }
}

function hashPassword(bcrypt, password) {
  if (typeof password !== 'string' || password.length < MIN_LENGTH) {
    throw new Error(`N8N_OWNER_PASSWORD must be at least ${MIN_LENGTH} characters`);
  }
  if (Buffer.byteLength(password, 'utf8') > MAX_BYTES) {
    throw new Error(`N8N_OWNER_PASSWORD must be at most ${MAX_BYTES} bytes (bcrypt limit)`);
  }
  const hash = bcrypt.hashSync(password, ROUNDS);
  if (!HASH_PATTERN.test(hash) || !bcrypt.compareSync(password, hash)) {
    throw new Error('bcryptjs returned a hash n8n would not accept');
  }
  return hash;
}

function main(args, env) {
  const bcrypt = loadBcrypt();
  if (args.includes('--self-test')) {
    hashPassword(bcrypt, SELF_TEST_PASSWORD);
    process.stdout.write('bcryptjs from n8n works\n');
    return;
  }
  process.stdout.write(hashPassword(bcrypt, env.N8N_OWNER_PASSWORD));
}

try {
  main(process.argv.slice(2), process.env);
} catch (error) {
  process.stderr.write(`[railway-n8n] ${error.message}\n`);
  process.exit(1);
}
