const fs = require('fs');
const path = require('path');

const indexPath = path.join(__dirname, '..', 'lib', 'index.js');
if (!fs.existsSync(indexPath)) {
  console.error('Error: lib/index.js not found. Run "tsc" build first.');
  process.exit(1);
}

const funcs = require(indexPath);
const manifestPath = path.join(__dirname, '..', 'functions.yaml');

if (!fs.existsSync(manifestPath)) {
  console.error('Error: functions.yaml not found.');
  process.exit(1);
}

const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
const manifestEndpoints = Object.keys(manifest.endpoints || {});

const exportedFuncs = Object.keys(funcs).filter(
  (k) => funcs[k] && funcs[k].__endpoint
);

const missing = exportedFuncs.filter((k) => !manifestEndpoints.includes(k));

if (missing.length > 0) {
  console.error(
    `[validate-manifest] FAILED: The following exported Cloud Functions are missing from functions.yaml:\n  ${missing.join(
      ', '
    )}`
  );
  process.exit(1);
}

console.log(
  `[validate-manifest] PASSED: All ${exportedFuncs.length} exported Cloud Functions are present in functions.yaml.`
);
