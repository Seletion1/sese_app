const fs = require('fs');
const path = require('path');

async function main() {
  const configPath = path.join(process.env.HOME, '.config/configstore/firebase-tools.json');
  const fbConfig = JSON.parse(fs.readFileSync(configPath, 'utf8'));
  const accessToken = fbConfig.tokens.access_token;

  const tooltips = {
    menu_credits: {
      title: 'Sese Credits',
      description: 'Manage platform dispatch credits used strictly to settle trip commissions.',
      enabled: true,
      maxViews: 2,
    },
    menu_earnings: {
      title: 'Earnings',
      description: 'Track daily, weekly, and monthly trip earnings, commissions, and net profit.',
      enabled: true,
      maxViews: 2,
    },
    menu_referral: {
      title: 'Refer & Earn',
      description: 'Share your referral code with friends and drivers.',
      enabled: true,
      maxViews: 2,
    },
    menu_trips_history: {
      title: 'Trips History',
      description: 'Review complete lifetime trip logs, receipts, routes, and order lifecycle statuses.',
      enabled: true,
      maxViews: 2,
    },
    menu_support: {
      title: 'Support',
      description: 'Access 24/7 dedicated support, emergency assistance, safety protocols, and live chat.',
      enabled: true,
      maxViews: 2,
    },
    menu_settings: {
      title: 'Settings',
      description: 'Configure vehicle fleet, order sounds, app theme (dark/light), and privacy settings.',
      enabled: true,
      maxViews: 2,
    },
    menu_trip_history: {
      title: 'Trip History',
      description: 'Completed trips, parcel delivery details, and ride receipts appear here.',
      enabled: true,
      maxViews: 2,
    },
    sese_credits: {
      title: 'Sese Credits',
      description: 'Non-withdrawable platform service credits used strictly for commission settlement.',
      enabled: true,
      maxViews: 2,
    },
    dispatch_mode: {
      title: 'Service Mode',
      description: 'Select Ride-Hailing to book a vehicle, or Package Delivery to send or receive parcels.',
      enabled: true,
      maxViews: 2,
    },
    delivery_pin_verification: {
      title: 'Delivery Security PIN',
      description: 'When enabled, the driver cannot complete the delivery without entering the secret 4-digit code given to the recipient.',
      enabled: true,
      maxViews: 2,
    },
  };

  console.log('Writing awareness tooltips to Firestore system_configs/awareness_tooltips...');
  const firestoreUrl = `https://firestore.googleapis.com/v1/projects/sese-ride/databases/(default)/documents/system_configs/awareness_tooltips`;

  const fields = Object.fromEntries(
    Object.entries(tooltips).map(([k, v]) => [
      k,
      {
        mapValue: {
          fields: {
            title: { stringValue: v.title },
            description: { stringValue: v.description },
            enabled: { booleanValue: v.enabled },
            maxViews: { integerValue: String(v.maxViews) },
          },
        },
      },
    ])
  );

  const fsRes = await fetch(firestoreUrl, {
    method: 'PATCH',
    headers: {
      'Authorization': `Bearer ${accessToken}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ fields }),
  });

  if (!fsRes.ok) {
    console.error('Firestore sync failed:', fsRes.status, await fsRes.text());
    process.exit(1);
  }

  console.log('Firestore system_configs/awareness_tooltips updated successfully!');
}

main().catch(err => {
  console.error('Fatal error:', err);
  process.exit(1);
});
