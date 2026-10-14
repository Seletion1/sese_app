import 'package:flutter/material.dart';
import 'package:sese_core/sese_core.dart';

/// Top-navigation SeSe Coin header chip: coin icon + live bonus balance.
///
/// 1 SeSe Coin = ₦1 of local currency. All referral / promo / streak
/// credits land in `seseCoinBalance` (never directly withdrawable).
/// Feeds: referral commissions, streak awards, campaign prizes, all bonuses.
/// Does NOT receive: card/bank top-ups, P2P transfers, or trip cash payouts.
class SeseCoinHeader extends StatelessWidget {
  final String uid;
  final SeseCoinService? service;

  const SeseCoinHeader({
    super.key,
    required this.uid,
    this.service,
  });

  @override
  Widget build(BuildContext context) {
    final svc = service ?? const SeseCoinService();
    return StreamBuilder<DualWallet>(
      stream: svc.walletStream(uid),
      builder: (context, snap) {
        final coins = snap.data?.seseCoinBalance ?? 0;
        return Container(
          padding: const EdgeInsets.symmetric(
              horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: const Color(0xFFFFF6D6),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
                color: const Color(0xFFEAA200), width: 1),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.monetization_on,
                  size: 18, color: Color(0xFFEAA200)),
              const SizedBox(width: 4),
              Text(
                '₦${coins.toStringAsFixed(2)}',
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// SeSe Coin Bonus card: routing-rule summary + manual conversion + auto-sweep info.
///
/// ### Routing rules (mirrored from Cloud Functions)
/// - `mainWalletBalance` — card/bank top-ups, P2P transfers, trip cash payouts.
/// - `seseCoinBalance` — ALL promotional rewards, referral commissions,
///   campaign prizes, and system streak bonuses.
///
/// ### Conversion thresholds
/// - **Manual**: once `seseCoinBalance >= minConvertibleBonus` (default ₦5,000),
///   the "Convert to Main Balance" button becomes active.
/// - **Auto-sweep**: when `seseCoinBalance >= maxBonusThreshold` (default ₦10,000),
///   the full coin balance sweeps into `mainWalletBalance` in real time via the
///   `processReferralCredit` Cloud Function. The client never triggers this.
class SeseCoinConvertCard extends StatelessWidget {
  final String uid;
  final SeseCoinService? coinService;
  final FinancialConfigService? configService;

  const SeseCoinConvertCard({
    super.key,
    required this.uid,
    this.coinService,
    this.configService,
  });

  @override
  Widget build(BuildContext context) {
    final coins = coinService ?? const SeseCoinService();
    final cfg = configService ?? const FinancialConfigService();
    return StreamBuilder<DualWallet>(
      stream: coins.walletStream(uid),
      builder: (context, wSnap) {
        final wallet = wSnap.data ?? const DualWallet();
        return StreamBuilder<FinancialConfig>(
          stream: cfg.configStream(),
          builder: (context, cSnap) {
            final config =
                cSnap.data ?? const FinancialConfig();
            final eligible = wallet.seseCoinBalance >=
                config.minConvertibleBonus;
            return Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment:
                      CrossAxisAlignment.start,
                  children: [
                    // ── Header row ─────────────────────────────
                    Row(
                      children: [
                        const Icon(Icons.monetization_on,
                            color: Color(0xFFEAA200)),
                        const SizedBox(width: 8),
                        const Expanded(
                          child: Text('SeSe Coin Bonus',
                              style: TextStyle(
                                  fontWeight: FontWeight.bold)),
                        ),
                        Text(
                          '₦${wallet.seseCoinBalance.toStringAsFixed(2)}',
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),

                    // ── Routing rules summary ───────────────────
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFFF8E1),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                            color: const Color(0xFFEAA200)
                                .withValues(alpha: 0.4)),
                      ),
                      child: Column(
                        crossAxisAlignment:
                            CrossAxisAlignment.start,
                        children: const [
                          Text(
                            'What goes into SeSe Coins:',
                            style: TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 11,
                                color: Color(0xFF7A5300)),
                          ),
                          SizedBox(height: 4),
                          Text(
                            '• Referral commissions\n'
                            '• Streak & completion bonuses\n'
                            '• Campaign prizes & promo rewards',
                            style: TextStyle(
                                fontSize: 11,
                                color: Color(0xFF7A5300)),
                          ),
                          SizedBox(height: 6),
                          Text(
                            'Your Main Cash Wallet receives:',
                            style: TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 11,
                                color: Color(0xFF555555)),
                          ),
                          SizedBox(height: 4),
                          Text(
                            '• Card / bank top-ups\n'
                            '• P2P transfers ("Send to a SeSe user")\n'
                            '• Completed trip cash payouts',
                            style: TextStyle(
                                fontSize: 11,
                                color: Color(0xFF555555)),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),

                    // ── Convert button ──────────────────────────
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        key: const Key(
                            'convert_coins_button'),
                        icon: const Icon(
                            Icons.swap_horiz_outlined),
                        label: Text(
                          eligible
                              ? 'Convert to Main Balance'
                              : 'Convert unlocks at ₦${config.minConvertibleBonus.toStringAsFixed(0)}',
                        ),
                        onPressed: eligible
                            ? () => _convert(context)
                            : null,
                      ),
                    ),

                    // ── Auto-sweep label ────────────────────────
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        const Icon(Icons.autorenew,
                            size: 13, color: Colors.grey),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            'Auto-sweeps to main wallet at '
                            '₦${config.maxBonusThreshold.toStringAsFixed(0)} — no action needed.',
                            style: const TextStyle(
                                fontSize: 11,
                                color: Colors.grey),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }


  Future<void> _convert(BuildContext context) async {
    final svc = coinService ?? const SeseCoinService();
    try {
      final converted = await svc.convertToWallet();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
                '₦${converted.toStringAsFixed(2)} moved to your cash wallet.'),
            backgroundColor: Colors.green.shade800,
          ),
        );
      }
    } on SeseCoinException catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message)),
        );
      }
    }
  }
}
