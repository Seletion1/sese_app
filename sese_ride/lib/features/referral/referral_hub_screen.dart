import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:sese_core/sese_core.dart';

/// Dedicated Referral Hub inside the Account/Menu tab.
///
/// Shows the user's unique code, live accumulated Sese Credits balance,
/// and copy + share actions.
class ReferralHubScreen extends StatelessWidget {
  final AppUser user;

  const ReferralHubScreen({super.key, required this.user});

  Stream<({bool isVerified, String memberId})> _memberStatusStream() {
    try {
      final collection = user.role == UserRole.driver ? 'drivers' : 'users';
      return FirebaseFirestore.instance
          .collection(collection)
          .doc(user.uid)
          .snapshots()
          .map((s) {
        final data = s.data();
        if (data == null) {
          return (
            isVerified: user.isVerified,
            memberId: user.sequentialId,
          );
        }
        final status = (data['verificationStatus'] ?? '').toString().toLowerCase();
        final custStatus =
            (data['customerVerificationStatus'] ?? '').toString().toLowerCase();
        final isVerified = data['isProfileVerified'] == true ||
            data['isVerifiedCustomer'] == true ||
            status == 'verified' ||
            status == 'approved' ||
            custStatus == 'verified' ||
            custStatus == 'approved';
        final memberId = (data['sequentialId'] ?? '').toString().trim();
        return (isVerified: isVerified, memberId: memberId);
      });
    } catch (_) {
      return Stream.value((
        isVerified: user.isVerified,
        memberId: user.sequentialId,
      ));
    }
  }

  Stream<double> _seseCreditsStream() {
    try {
      return FirebaseFirestore.instance
          .collection('wallets')
          .doc(user.uid)
          .snapshots()
          .map((s) {
        final data = s.data();
        if (data == null) return 0.0;
        return (data['seseCredits'] as num?)?.toDouble() ?? 0.0;
      });
    } catch (_) {
      return Stream.value(0.0);
    }
  }

  Future<void> _copy(BuildContext context, String code) async {
    if (code.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: code));
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Referral code copied.')),
      );
    }
  }

  Future<void> _share(BuildContext context, String code) async {
    if (code.isEmpty) return;
    final box = context.findRenderObject() as RenderBox?;
    final origin =
        box != null ? (box.localToGlobal(Offset.zero) & box.size) : null;
    await SharePlus.instance.share(
      ShareParams(
        text: 'Ride with me on SeSe! Use my referral code $code when you sign up. #SeSeRide',
        subject: 'My SeSe referral code: $code',
        sharePositionOrigin: origin,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Referral Credits'),
        actions: [
          SettingsInfoButton(
            tooltipId: 'menu_referral',
            userId: user.uid,
            title: 'Invite Friends',
            description:
                'Share your referral code with friends and drivers to earn 1% Sese Credits on every completed trip.',
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ── Accumulated Sese Credits Card ────────────────────────────────
          StreamBuilder<double>(
            stream: _seseCreditsStream(),
            builder: (context, snap) {
              final credits = snap.data ?? 0.0;
              return Card(
                color: Colors.amber.shade50.withOpacity(0.9),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: BorderSide(color: Colors.amber.shade300, width: 1),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.amber.shade100,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.card_giftcard, color: Colors.amber, size: 28),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Accumulated Sese Credits',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                                color: Colors.black54,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '₦${credits.toStringAsFixed(2)}',
                              style: const TextStyle(
                                fontSize: 26,
                                fontWeight: FontWeight.bold,
                                color: Colors.black87,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (kIsWeb) ...[
                        const SizedBox(width: 12),
                        ElevatedButton.icon(
                          key: const Key('referral_web_cashout_button'),
                          icon: const Icon(Icons.account_balance_wallet_outlined, size: 18),
                          label: const Text('Cash Out'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.amber.shade700,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            elevation: 0,
                          ),
                          onPressed: credits >= 1000
                              ? () => showDialog<void>(
                                    context: context,
                                    builder: (_) => _WebCashOutDialog(
                                      user: user,
                                      availableCredits: credits,
                                    ),
                                  )
                              : null,
                        ),
                      ],
                    ],
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 16),

          // ── Unified Member ID / Referral Code Card (Verified Only) ────────
          StreamBuilder<({bool isVerified, String memberId})>(
            stream: _memberStatusStream(),
            initialData: (
              isVerified: user.isVerified,
              memberId: user.sequentialId,
            ),
            builder: (context, snap) {
              final state = snap.data ??
                  (isVerified: user.isVerified, memberId: user.sequentialId);
              final isVerifiedWithId =
                  state.isVerified && state.memberId.isNotEmpty;

              if (!isVerifiedWithId) {
                return Card(
                  key: const Key('referral_verification_prompt_card'),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                    side: BorderSide(color: Colors.amber.shade200),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.verified_user_outlined,
                              color: Colors.amber.shade800,
                              size: 24,
                            ),
                            const SizedBox(width: 10),
                            const Expanded(
                              child: Text(
                                'Account Verification Required',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Text(
                          'Verify your account first to receive your official SeSe Member ID and refer friends to earn 1% Sese Credits.',
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                color: Colors.grey[700],
                                height: 1.4,
                              ),
                        ),
                      ],
                    ),
                  ),
                );
              }

              final code = state.memberId;
              return Card(
                key: const Key('referral_code_card'),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Your Referral Code (Member ID)',
                        style: TextStyle(
                            color: Colors.grey, fontWeight: FontWeight.w500),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        code,
                        style: const TextStyle(
                          fontSize: 36,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 2,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(
                            child: FilledButton.icon(
                              key: const Key('referral_copy_button'),
                              icon: const Icon(Icons.copy),
                              label: const Text('Copy Code'),
                              onPressed: () => _copy(context, code),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: OutlinedButton.icon(
                              key: const Key('referral_share_button'),
                              icon: const Icon(Icons.share),
                              label: const Text('Share'),
                              onPressed: () => _share(context, code),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 16),

          // ── Active Referrals List (Compact Row Layout) ─────────────────────
          Text(
            'ACTIVE REFERRALS',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                  color: Colors.grey,
                ),
          ),
          const SizedBox(height: 10),
          _ActiveReferralsSection(
            userId: user.uid,
            isDark: Theme.of(context).brightness == Brightness.dark,
          ),
          const SizedBox(height: 16),

          // ── Program Rules Card ──────────────────────────────────────────
          Card(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Padding(
              padding: EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'How Sese Credits Work',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  SizedBox(height: 12),
                  _RuleRow(
                    icon: Icons.percent,
                    title: '1% Credit on Completed Trips',
                    description:
                        'Earn 1% Sese Credits on every completed trip made by users and drivers you refer.',
                  ),
                  SizedBox(height: 12),
                  _RuleRow(
                    icon: Icons.discount_outlined,
                    title: 'Automatic Trip Discounts',
                    description:
                        'For passengers, Sese Credits automatically apply as a Trip Discount at checkout.',
                  ),
                  SizedBox(height: 12),
                  _RuleRow(
                    icon: Icons.build_circle_outlined,
                    title: 'Platform Fee Offset',
                    description:
                        'For drivers, Sese Credits directly offset platform commission fees on future trips.',
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ActiveReferralData {
  final String refereeUid;
  final String firstName;
  final int completedTrips;
  final double earnedNaira;
  final DateTime signupTime;

  const _ActiveReferralData({
    required this.refereeUid,
    required this.firstName,
    required this.completedTrips,
    required this.earnedNaira,
    required this.signupTime,
  });

  /// Formatted live countdown e.g. `354d remaining`, `7h remaining`, `15m remaining`.
  String get countdownText {
    final expiry = signupTime.add(const Duration(days: 365));
    final remaining = expiry.difference(DateTime.now());
    if (remaining.isNegative || remaining.inSeconds <= 0) {
      return 'Expired';
    }
    if (remaining.inDays >= 1) {
      return '${remaining.inDays}d remaining';
    }
    if (remaining.inHours >= 1) {
      return '${remaining.inHours}h remaining';
    }
    if (remaining.inMinutes > 0) {
      return '${remaining.inMinutes}m remaining';
    }
    return '<1m remaining';
  }

  bool get isExpired {
    final expiry = signupTime.add(const Duration(days: 365));
    return expiry.difference(DateTime.now()).isNegative;
  }
}

class _ActiveReferralsSection extends StatelessWidget {
  final String userId;
  final bool isDark;

  const _ActiveReferralsSection({
    required this.userId,
    required this.isDark,
  });

  static String _extractFirstName(dynamic rawFirst, dynamic rawFull, dynamic rawDisplay) {
    final f = (rawFirst ?? '').toString().trim();
    if (f.isNotEmpty) return f.split(RegExp(r'\s+')).first;

    final full = (rawFull ?? '').toString().trim();
    if (full.isNotEmpty) return full.split(RegExp(r'\s+')).first;

    final disp = (rawDisplay ?? '').toString().trim();
    if (disp.isNotEmpty) return disp.split(RegExp(r'\s+')).first;

    return 'Member';
  }

  static DateTime _parseDate(dynamic raw) {
    if (raw != null) {
      try {
        if (raw is Timestamp) return raw.toDate();
        if ((raw as dynamic).toDate != null) {
          return (raw as dynamic).toDate() as DateTime;
        }
      } catch (_) {}
      if (raw is String) {
        final parsed = DateTime.tryParse(raw);
        if (parsed != null) return parsed;
      }
    }
    return DateTime.now();
  }

  Stream<List<_ActiveReferralData>> _referralsStream() {
    try {
      final db = FirebaseFirestore.instance;
      // Stream user referrals subcollection
      return db
          .collection('users')
          .doc(userId)
          .collection('referrals')
          .snapshots()
          .asyncMap((snap) async {
        final list = <_ActiveReferralData>[];
        final seenUids = <String>{};

        for (final doc in snap.docs) {
          final d = doc.data();
          final uid = doc.id;
          seenUids.add(uid);

          final firstName = _extractFirstName(
            d['refereeFirstName'],
            d['fullName'],
            d['displayName'],
          );
          final trips = (d['completedTrips'] as num?)?.toInt() ?? 0;
          final earned = (d['totalEarnedNaira'] as num?)?.toDouble() ?? 0.0;
          final signupTime = _parseDate(d['referralSignupAt'] ?? d['createdAt']);

          final item = _ActiveReferralData(
            refereeUid: uid,
            firstName: firstName,
            completedTrips: trips,
            earnedNaira: earned,
            signupTime: signupTime,
          );

          if (!item.isExpired) {
            list.add(item);
          }
        }

        // Also query fallback users and drivers where referredBy == userId
        try {
          final uSnap = await db
              .collection('users')
              .where('referredBy', isEqualTo: userId)
              .get();
          for (final doc in uSnap.docs) {
            if (seenUids.contains(doc.id)) continue;
            seenUids.add(doc.id);
            final d = doc.data();
            final firstName = _extractFirstName(d['firstName'], d['fullName'], d['displayName']);
            final trips = (d['completedTrips'] as num?)?.toInt() ?? 0;
            final signupTime = _parseDate(d['referralSignupAt'] ?? d['createdAt']);
            final item = _ActiveReferralData(
              refereeUid: doc.id,
              firstName: firstName,
              completedTrips: trips,
              earnedNaira: 0.0,
              signupTime: signupTime,
            );
            if (!item.isExpired) list.add(item);
          }

          final dSnap = await db
              .collection('drivers')
              .where('referredBy', isEqualTo: userId)
              .get();
          for (final doc in dSnap.docs) {
            if (seenUids.contains(doc.id)) continue;
            seenUids.add(doc.id);
            final d = doc.data();
            final firstName = _extractFirstName(d['firstName'], d['fullName'], d['displayName']);
            final trips = (d['completedTrips'] as num?)?.toInt() ?? 0;
            final signupTime = _parseDate(d['referralSignupAt'] ?? d['createdAt']);
            final item = _ActiveReferralData(
              refereeUid: doc.id,
              firstName: firstName,
              completedTrips: trips,
              earnedNaira: 0.0,
              signupTime: signupTime,
            );
            if (!item.isExpired) list.add(item);
          }
        } catch (_) {}

        list.sort((a, b) => b.signupTime.compareTo(a.signupTime));
        return list;
      });
    } catch (_) {
      return Stream.value(const <_ActiveReferralData>[]);
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<_ActiveReferralData>>(
      stream: _referralsStream(),
      builder: (context, snap) {
        final items = snap.data ?? const <_ActiveReferralData>[];

        if (items.isEmpty) {
          return Container(
            padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF252530) : Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: isDark ? const Color(0xFF3A3A46) : Colors.grey.shade200,
              ),
            ),
            child: Text(
              'No active referrals yet. Share your code above to start earning!',
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: Colors.grey.shade600, fontSize: 13),
              textAlign: TextAlign.center,
            ),
          );
        }

        return ListView.separated(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: items.length,
          separatorBuilder: (_, _) => const SizedBox(height: 8),
          itemBuilder: (context, index) {
            final item = items[index];
            return Container(
              key: Key('active_referral_item_${item.refereeUid}'),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF252530) : Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: isDark ? const Color(0xFF3A3A46) : Colors.grey.shade200,
                ),
              ),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 18,
                    backgroundColor: Colors.amber.shade100,
                    child: Text(
                      item.firstName.isNotEmpty
                          ? item.firstName[0].toUpperCase()
                          : 'M',
                      style: const TextStyle(
                        color: Colors.black87,
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.firstName,
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          item.countdownText,
                          style: TextStyle(
                            fontSize: 11,
                            color: Colors.grey.shade600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        '₦${item.earnedNaira.toStringAsFixed(2)}',
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                          color: Colors.green,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${item.completedTrips} trips',
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.grey.shade600,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

class _RuleRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;

  const _RuleRow({
    required this.icon,
    required this.title,
    required this.description,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 20, color: Colors.amber.shade700),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
              ),
              const SizedBox(height: 2),
              Text(
                description,
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Web-Only Cash Out dialog.
class _WebCashOutDialog extends StatefulWidget {
  final AppUser user;
  final double availableCredits;

  const _WebCashOutDialog({
    required this.user,
    required this.availableCredits,
  });

  @override
  State<_WebCashOutDialog> createState() => _WebCashOutDialogState();
}

class _WebCashOutDialogState extends State<_WebCashOutDialog> {
  late final TextEditingController _amountCtrl;
  late final TextEditingController _bankNameCtrl;
  late final TextEditingController _accountNumCtrl;
  late final TextEditingController _accountNameCtrl;

  bool _submitting = false;
  String? _error;

  static const List<Map<String, String>> _popularBanks = [
    {'name': 'Access Bank', 'code': '044'},
    {'name': 'GTBank (Guaranty Trust Bank)', 'code': '058'},
    {'name': 'First Bank of Nigeria', 'code': '011'},
    {'name': 'Zenith Bank', 'code': '057'},
    {'name': 'UBA (United Bank for Africa)', 'code': '033'},
    {'name': 'Kuda Bank', 'code': '50211'},
    {'name': 'OPay', 'code': '999992'},
    {'name': 'PalmPay', 'code': '999991'},
    {'name': 'Moniepoint Microfinance Bank', 'code': '50515'},
    {'name': 'Stanbic IBTC Bank', 'code': '221'},
  ];

  String _selectedBankCode = '044';
  String _selectedBankName = 'Access Bank';

  @override
  void initState() {
    super.initState();
    final initialAmount = widget.availableCredits >= 1000 ? 1000.0 : widget.availableCredits;
    _amountCtrl = TextEditingController(text: initialAmount.toStringAsFixed(0));
    _bankNameCtrl = TextEditingController(text: _selectedBankName);
    _accountNumCtrl = TextEditingController();
    _accountNameCtrl = TextEditingController(text: widget.user.fullName);
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    _bankNameCtrl.dispose();
    _accountNumCtrl.dispose();
    _accountNameCtrl.dispose();
    super.dispose();
  }

  Future<void> _submitCashOut() async {
    if (_submitting) return;
    setState(() {
      _submitting = true;
      _error = null;
    });

    final amount = double.tryParse(_amountCtrl.text.trim()) ?? 0.0;
    if (amount < 1000) {
      setState(() {
        _error = 'Minimum referral cash-out amount is ₦1,000.00.';
        _submitting = false;
      });
      return;
    }

    if (amount > widget.availableCredits) {
      setState(() {
        _error = 'Requested amount exceeds available balance (₦${widget.availableCredits.toStringAsFixed(2)}).';
        _submitting = false;
      });
      return;
    }

    final accountNum = _accountNumCtrl.text.trim().replaceAll(RegExp(r'\D'), '');
    if (accountNum.length < 10) {
      setState(() {
        _error = 'Please enter a valid 10-digit account number.';
        _submitting = false;
      });
      return;
    }

    final accountName = _accountNameCtrl.text.trim();
    if (accountName.isEmpty) {
      setState(() {
        _error = 'Please enter the account holder name.';
        _submitting = false;
      });
      return;
    }

    try {
      final callable = FirebaseFunctions.instance.httpsCallable('requestReferralCashOut');
      final res = await callable.call<Map<String, dynamic>>({
        'amountNaira': amount,
        'bankCode': _selectedBankCode,
        'bankName': _selectedBankName,
        'accountNumber': accountNum,
        'accountName': accountName,
        'idempotencyKey': 'web_cashout_${widget.user.uid}_${DateTime.now().millisecondsSinceEpoch}',
      });

      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            (res.data['message'] ?? 'Referral cash-out request submitted successfully!').toString(),
          ),
          backgroundColor: Colors.green.shade800,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is FirebaseFunctionsException ? e.message : 'Cash-out request failed. Please try again.';
        _submitting = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.account_balance_wallet_outlined, color: Colors.amber),
          SizedBox(width: 8),
          Text('Referral Cash Out'),
        ],
      ),
      content: SingleChildScrollView(
        child: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.amber.shade50,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.amber.shade200),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Available Credits:', style: TextStyle(fontWeight: FontWeight.w500)),
                    Text(
                      '₦${widget.availableCredits.toStringAsFixed(2)}',
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _amountCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Amount (₦)',
                  hintText: 'e.g. 2000',
                  prefixText: '₦ ',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                value: _selectedBankCode,
                decoration: const InputDecoration(
                  labelText: 'Select Bank',
                  border: OutlineInputBorder(),
                ),
                items: _popularBanks.map((b) {
                  return DropdownMenuItem<String>(
                    value: b['code'],
                    child: Text(b['name'] ?? ''),
                  );
                }).toList(),
                onChanged: (val) {
                  if (val != null) {
                    final found = _popularBanks.firstWhere((b) => b['code'] == val, orElse: () => _popularBanks.first);
                    setState(() {
                      _selectedBankCode = val;
                      _selectedBankName = found['name'] ?? 'Bank';
                    });
                  }
                },
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _accountNumCtrl,
                keyboardType: TextInputType.number,
                maxLength: 10,
                decoration: const InputDecoration(
                  labelText: 'Account Number (10 Digits)',
                  hintText: 'e.g. 0123456789',
                  border: OutlineInputBorder(),
                  counterText: '',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _accountNameCtrl,
                decoration: const InputDecoration(
                  labelText: 'Account Holder Name',
                  hintText: 'e.g. John Doe',
                  border: OutlineInputBorder(),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: const TextStyle(color: Colors.red, fontSize: 12, fontWeight: FontWeight.w500),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.amber.shade700,
            foregroundColor: Colors.white,
          ),
          onPressed: _submitting ? null : _submitCashOut,
          child: _submitting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                )
              : const Text('Submit Cash Out'),
        ),
      ],
    );
  }
}
