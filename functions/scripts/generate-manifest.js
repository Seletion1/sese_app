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
  if (fn && typeof fn === 'object' && fn.__endpoint) {
    endpoints[name] = {
      ...fn.__endpoint,
      entryPoint: name,
    };
  } else if (fn && typeof fn === 'function' && fn.__endpoint) {
    endpoints[name] = {
      ...fn.__endpoint,
      entryPoint: name,
    };
  }
}

const manifest = {
  specVersion: 'v1alpha1',
  endpoints,
};

const outputPath = path.join(__dirname, '..', 'functions.yaml');
fs.writeFileSync(outputPath, JSON.stringify(manifest, null, 2) + '\n', 'utf8');
console.log(
  `[generate-manifest] Successfully generated functions.yaml with ${
    Object.keys(endpoints).length
  } endpoints.`
);
