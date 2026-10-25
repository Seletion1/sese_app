const fs = require('fs');
const path = require('path');

async function main() {
  const configPath = path.join(process.env.HOME, '.config/configstore/firebase-tools.json');
  const fbConfig = JSON.parse(fs.readFileSync(configPath, 'utf8'));
  const accessToken = fbConfig.tokens.access_token;

  const tooltips = {
    menu_wallet: {
      title: 'Wallet',
      description: 'Manage funds, top up balance, withdraw to your Nigerian bank, and view real-time transaction ledger.',
      enabled: true,
      maxViews: 2,
    },
    menu_earnings: {
      title: 'Earnings',
      description: 'Track daily, weekly, and monthly trip earnings, commissions, net profit, and streak milestones.',
      enabled: true,
      maxViews: 2,
    },
    menu_referral: {
      title: 'Refer & Earn',
      description: 'Share your referral code with friends and drivers to earn lifetime commission bonus coins.',
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
    menu_wallet___payments: {
      title: 'Wallet & Payments',
      description: 'Manage your payment balance, linked debit cards, and transaction history.',
      enabled: true,
      maxViews: 2,
    },
    menu_saved_places: {
      title: 'Saved Places',
      description: 'Bookmark your Home, Work, and frequent addresses for zero-cost instant booking.',
      enabled: true,
      maxViews: 2,
    },
    menu_bank___payout_details: {
      title: 'Bank & Payout Details',
      description: 'Link and verify your Nigerian bank account for instant withdrawal settlements.',
      enabled: true,
      maxViews: 2,
    },
    menu_security_pin: {
      title: 'Security PIN',
      description: 'Protect your account, withdrawals, and wallet transfers with a secure 4-digit PIN.',
      enabled: true,
      maxViews: 2,
    },
    sese_coin: {
      title: 'SeSe Coin Balance',
      description: 'Bonus rewards earned from referrals and streaks. 1 SeSe Coin = ₦1, converting to main cash upon reaching threshold.',
      enabled: true,
      maxViews: 2,
    },
    wallet_balance: {
      title: 'Wallet Balance',
      description: 'Withdrawable cash balance available for trips, peer transfers, and bank payouts.',
      enabled: true,
      maxViews: 2,
    },
    payment_mode: {
      title: 'Payment Mode',
      description: 'Choose who pays for the trip: Sender at pickup, Receiver at drop-off, or Split Payment between both.',
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
