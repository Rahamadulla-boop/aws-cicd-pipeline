/**
 * Cross-platform JavaScript syntax linter
 */
const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

const targetDirs = ['src', 'tests', 'public'];
let totalChecked = 0;

for (const dir of targetDirs) {
  const dirPath = path.join(__dirname, '..', dir);
  if (!fs.existsSync(dirPath)) continue;

  const files = fs.readdirSync(dirPath).filter(f => f.endsWith('.js'));
  for (const file of files) {
    const filePath = path.join(dirPath, file);
    execSync(`node --check "${filePath}"`, { stdio: 'inherit' });
    totalChecked++;
  }
}

console.log(`[LINT_SUCCESS] Successfully verified syntax across ${totalChecked} JavaScript files.`);
