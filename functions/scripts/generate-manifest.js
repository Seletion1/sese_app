const fs = require('fs');
const path = require('path');

const indexPath = path.join(__dirname, '..', 'lib', 'index.js');
if (!fs.existsSync(indexPath)) {
  console.error('Error: lib/index.js not found. Run "tsc" build first.');
  process.exit(1);
}

const funcs = require(indexPath);
const endpoints = {};

for (const [name, fn] of Object.entries(funcs)) {
  const ep =
    (fn && typeof fn === 'object' && fn.__endpoint) ||
    (fn && typeof fn === 'function' && fn.__endpoint);
  if (ep) {
    endpoints[name] = {
      platform: ep.platform || 'gcfv2',
      ...ep,
      entryPoint: name,
    };
  }
}

const manifest = {
  specVersion: 'v1alpha1',
  requiredAPIs: [
    { api: 'cloudfunctions.googleapis.com', reason: 'Needed for Cloud Functions' },
    { api: 'run.googleapis.com', reason: 'Needed for 2nd Gen Cloud Functions' },
    { api: 'eventarc.googleapis.com', reason: 'Needed for Eventarc triggers' },
  ],
  endpoints,
};

const outputPath = path.join(__dirname, '..', 'functions.yaml');
fs.writeFileSync(outputPath, JSON.stringify(manifest, null, 2) + '\n', 'utf8');
console.log(
  `[generate-manifest] Successfully generated functions.yaml with ${
    Object.keys(endpoints).length
  } Gen-2 endpoints.`
);
