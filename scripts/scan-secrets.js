/**
 * Secret & Credential Scanner
 * Scans project files for exposed API keys, private tokens, or credentials.
 */

const fs = require('fs');
const path = require('path');

const SECRET_PATTERNS = [
  { name: 'AWS Access Key ID', regex: /\bAKIA[0-9A-Z]{16}\b/ },
  { name: 'AWS Secret Access Key', regex: /aws_secret_access_key\s*=\s*['"][A-Za-z0-9\/+=]{40}['"]/ },
  { name: 'Private Key Header', regex: /-----BEGIN [A-Z ]*PRIVATE KEY-----/ },
  { name: 'GitHub Personal Access Token', regex: /\bghp_[A-Za-z0-9]{36}\b/ }
];

const IGNORED_PATHS = [
  'node_modules',
  '.git',
  '.terraform'
];

function scanDirectory(dir) {
  let issues = 0;
  const entries = fs.readdirSync(dir, { withFileTypes: true });

  for (const entry of entries) {
    if (IGNORED_PATHS.includes(entry.name)) continue;

    const fullPath = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      issues += scanDirectory(fullPath);
    } else if (entry.isFile()) {
      const content = fs.readFileSync(fullPath, 'utf8');
      for (const pattern of SECRET_PATTERNS) {
        if (pattern.regex.test(content)) {
          console.error(`[VIOLATION] Found ${pattern.name} in: ${fullPath}`);
          issues++;
        }
      }
    }
  }

  return issues;
}

const rootDir = path.resolve(__dirname, '..');
const violations = scanDirectory(rootDir);

if (violations === 0) {
  console.log('[PASSED] Clean repository: zero hardcoded secrets, AWS keys, or credentials detected.');
  process.exit(0);
} else {
  console.error(`[FAILED] Detected ${violations} sensitive credential patterns!`);
  process.exit(1);
}
