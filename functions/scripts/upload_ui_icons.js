const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

async function main() {
  const configPath = path.join(process.env.HOME, '.config/configstore/firebase-tools.json');
  const fbConfig = JSON.parse(fs.readFileSync(configPath, 'utf8'));
  const accessToken = fbConfig.tokens.access_token;
  const bucketName = 'sese-ride.firebasestorage.app';

  const iconsDir = '/Users/micheal/.gemini/antigravity/brain/b37f6d18-7356-41f2-8a5f-03cb22ae2166/processed_icons';
  const files = fs.readdirSync(iconsDir).filter(f => f.endsWith('.png'));

  console.log(`Found ${files.length} icon files to upload.`);

  const iconKeyMap = {
    'sese_bicycle.png': 'vehicle_bicycle',
    'sese_motorcycle.png': 'vehicle_motorcycle',
    'sese_tricycle.png': 'vehicle_keke',
    'sese_car_sedan.png': 'vehicle_sedan',
    'sese_standard_comfort.png': 'vehicle_comfort',
    'sese_executive_premium.png': 'vehicle_premium',
    'sese_luxe_super.png': 'vehicle_luxe',
    'sese_van.png': 'vehicle_van',
    'sese_truck.png': 'vehicle_truck',
    'sese_send_box.png': 'sender_box',
    'sese_receiver_box.png': 'receiver_box',
  };

  const manifest = {
    version: 1,
    updatedAt: new Date().toISOString(),
    icons: {},
  };

  for (const file of files) {
    const filePath = path.join(iconsDir, file);
    const fileData = fs.readFileSync(filePath);
    const downloadToken = crypto.randomUUID();
    const destinationPath = `ui_assets/icons/${file}`;
    const encodedDest = encodeURIComponent(destinationPath);

    console.log(`Uploading ${file} (${fileData.length} bytes)...`);

    // Upload using GCS JSON API multipart upload or media upload with metadata
    const metadata = {
      name: destinationPath,
      contentType: 'image/png',
      metadata: {
        firebaseStorageDownloadTokens: downloadToken,
      },
    };

    // Multipart upload to attach metadata
    const boundary = '-------314159265358979323846';
    const delimiter = `\r\n--${boundary}\r\n`;
    const closeDelimiter = `\r\n--${boundary}--`;

    const multipartBody = Buffer.concat([
      Buffer.from(
        delimiter +
          'Content-Type: application/json; charset=UTF-8\r\n\r\n' +
          JSON.stringify(metadata) +
          delimiter +
          'Content-Type: image/png\r\n\r\n'
      ),
      fileData,
      Buffer.from(closeDelimiter),
    ]);

    const uploadUrl = `https://storage.googleapis.com/upload/storage/v1/b/${bucketName}/o?uploadType=multipart`;

    const res = await fetch(uploadUrl, {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${accessToken}`,
        'Content-Type': `multipart/related; boundary="${boundary}"`,
        'Content-Length': multipartBody.length.toString(),
      },
      body: multipartBody,
    });

    if (!res.ok) {
      const errText = await res.text();
      throw new Error(`Upload failed for ${file} [${res.status}]: ${errText}`);
    }

    const gcsResult = await res.json();
    const downloadUrl = `https://firebasestorage.googleapis.com/v0/b/${bucketName}/o/${encodedDest}?alt=media&token=${downloadToken}`;
    const key = iconKeyMap[file] || file.replace('.png', '');

    console.log(`Uploaded ${file} -> Key: ${key} -> URL: ${downloadUrl}`);

    manifest.icons[key] = {
      filename: file,
      url: downloadUrl,
      sizeBytes: fileData.length,
      md5: gcsResult.md5Hash,
      token: downloadToken,
    };
  }

  // Also write aliases for compatibility:
  // 'vehicle_tricycle' -> 'vehicle_keke'
  // 'vehicle_car' -> 'vehicle_sedan'
  // 'package_send' -> 'sender_box'
  // 'package_receive' -> 'receiver_box'
  if (manifest.icons['vehicle_keke']) {
    manifest.icons['vehicle_tricycle'] = { ...manifest.icons['vehicle_keke'] };
  }
  if (manifest.icons['vehicle_sedan']) {
    manifest.icons['vehicle_car'] = { ...manifest.icons['vehicle_sedan'] };
  }
  if (manifest.icons['sender_box']) {
    manifest.icons['package_send'] = { ...manifest.icons['sender_box'] };
  }
  if (manifest.icons['receiver_box']) {
    manifest.icons['package_receive'] = { ...manifest.icons['receiver_box'] };
  }

  // Save manifest file
  const outManifestPath = path.join(__dirname, '../../sese_core/assets/icons/icon_manifest.json');
  fs.mkdirSync(path.dirname(outManifestPath), { recursive: true });
  fs.writeFileSync(outManifestPath, JSON.stringify(manifest, null, 2));

  const rideManifestPath = path.join(__dirname, '../../sese_ride/assets/icons/icon_manifest.json');
  fs.mkdirSync(path.dirname(rideManifestPath), { recursive: true });
  fs.writeFileSync(rideManifestPath, JSON.stringify(manifest, null, 2));

  // Copy PNGs directly to both asset folders
  for (const file of files) {
    fs.copyFileSync(path.join(iconsDir, file), path.join(__dirname, '../../sese_core/assets/icons/', file));
    fs.copyFileSync(path.join(iconsDir, file), path.join(__dirname, '../../sese_ride/assets/icons/', file));
  }

  console.log('Successfully written icon_manifest.json and copied PNG assets to sese_core & sese_ride!');

  // Sync to Firestore system_configs/ui_icons
  console.log('Writing manifest to Firestore system_configs/ui_icons...');
  const firestoreUrl = `https://firestore.googleapis.com/v1/projects/sese-ride/databases/(default)/documents/system_configs/ui_icons`;
  
  // Convert manifest to Firestore format
  const fields = {
    version: { integerValue: String(manifest.version) },
    updatedAt: { stringValue: manifest.updatedAt },
    icons: {
      mapValue: {
        fields: Object.fromEntries(
          Object.entries(manifest.icons).map(([k, v]) => [
            k,
            {
              mapValue: {
                fields: {
                  filename: { stringValue: v.filename },
                  url: { stringValue: v.url },
                  sizeBytes: { integerValue: String(v.sizeBytes) },
                  token: { stringValue: v.token },
                },
              },
            },
          ])
        ),
      },
    },
  };

  const fsRes = await fetch(firestoreUrl, {
    method: 'PATCH',
    headers: {
      'Authorization': `Bearer ${accessToken}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ fields }),
  });

  if (!fsRes.ok) {
    console.warn('Firestore sync failed with status:', fsRes.status, await fsRes.text());
  } else {
    console.log('Firestore system_configs/ui_icons updated successfully!');
  }
}

main().catch(err => {
  console.error('Fatal error:', err);
  process.exit(1);
});
