import 'package:flutter/material.dart';
import 'package:sese_core/sese_core.dart';

/// "Bank Details" section under Wallet Settings.
///
/// Searchable bank dropdown (Paystack bank list via [BankService]) +
/// 10-digit account number field with real-time account-name verification.
/// Required before withdrawals / referral payouts.
class BankDetailsScreen extends StatefulWidget {
  final String uid;
  final BankService? bankService;

  const BankDetailsScreen({
    super.key,
    required this.uid,
    this.bankService,
  });

  @override
  State<BankDetailsScreen> createState() => _BankDetailsScreenState();
}

class _BankDetailsScreenState extends State<BankDetailsScreen> {
  late final BankService _svc = widget.bankService ?? const BankService();
  List<BankInfo> _banks = [];
  BankInfo? _selected;
  final _searchCtrl = TextEditingController();
  final _acctCtrl = TextEditingController();
  String? _resolvedName;
  bool _resolving = false;
  bool _saving = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _acctCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final banks = await _svc.fetchBanks();
    BankAccount saved = const BankAccount();
    try {
      saved = await _svc.fetchBankAccount(widget.uid);
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _banks = banks;
      _loading = false;
      if (saved.bankCode.isNotEmpty) {
        try {
          _selected =
              banks.firstWhere((b) => b.code == saved.bankCode);
        } catch (_) {
          _selected = BankInfo(
              name: saved.bankName,
              slug: '',
              code: saved.bankCode);
        }
        _acctCtrl.text = saved.accountNumber;
        _resolvedName =
            saved.accountName.isEmpty ? null : saved.accountName;
      }
    });
  }

  List<BankInfo> get _filtered {
    final q = _searchCtrl.text.trim().toLowerCase();
    if (q.isEmpty) return _banks;
    return _banks
        .where((b) => b.name.toLowerCase().contains(q))
        .toList();
  }

  Future<void> _onAccountChanged(String v) async {
    final digits = v.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits != v) {
      _acctCtrl.text = digits;
      _acctCtrl.selection = TextSelection.fromPosition(
          TextPosition(offset: _acctCtrl.text.length));
    }
    setState(() {
      _resolvedName = null;
    });
    if (_selected == null || digits.length != 10) return;
    setState(() => _resolving = true);
    final name = await _svc.resolveAccountName(
      bankCode: _selected!.code,
      accountNumber: digits,
    );
    if (!mounted) return;
    setState(() {
      _resolving = false;
      _resolvedName = name;
    });
  }

  Future<void> _save() async {
    if (_selected == null ||
        _acctCtrl.text.length != 10 ||
        (_resolvedName ?? '').isEmpty) {
      return;
    }
    setState(() => _saving = true);
    try {
      await _svc.saveBankAccount(
        widget.uid,
        BankAccount(
          bankName: _selected!.name,
          bankCode: _selected!.code,
          accountNumber: _acctCtrl.text,
          accountName: _resolvedName!,
          verifiedAt: DateTime.now(),
        ),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Bank details saved and verified.')),
      );
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      debugPrint('BankDetailsScreen save error: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              'Unable to save bank details. Please check connection and try again.'),
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final canSave = _selected != null &&
        _acctCtrl.text.length == 10 &&
        (_resolvedName ?? '').isNotEmpty &&
        !_saving;
    return Scaffold(
      appBar: AppBar(title: const Text('Bank Details')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Text(
                  'Payouts and withdrawals settle to this verified account. '
                  'Required if you have active referrals or a withdrawable '
                  'balance.',
                  style: TextStyle(fontSize: 13, color: Colors.grey),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _searchCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Search banks',
                    prefixIcon: Icon(Icons.search),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<BankInfo>(
                  key: const Key('bank_dropdown'),
                  initialValue: _selected,
                  isExpanded: true,
                  decoration: const InputDecoration(
                      labelText: 'Bank'),
                  items: [
                    for (final b in _filtered.take(60))
                      DropdownMenuItem(
                          value: b, child: Text(b.name)),
                  ],
                  onChanged: (v) {
                    setState(() {
                      _selected = v;
                      _resolvedName = null;
                    });
                    _onAccountChanged(_acctCtrl.text);
                  },
                ),
                const SizedBox(height: 12),
                TextFormField(
                  key: const Key('account_number_field'),
                  controller: _acctCtrl,
                  keyboardType: TextInputType.number,
                  maxLength: 10,
                  decoration: InputDecoration(
                    labelText: 'Account number',
                    suffixIcon: _resolving
                        ? const Padding(
                            padding: EdgeInsets.all(12),
                            child: SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2),
                            ),
                          )
                        : null,
                  ),
                  onChanged: _onAccountChanged,
                ),
                if (_resolvedName != null) ...[
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.green.shade50,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.verified,
                            color: Colors.green),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(_resolvedName!,
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold)),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                FilledButton.icon(
                  key: const Key('save_bank_button'),
                  icon: const Icon(Icons.save_outlined),
                  label: Text(
                      _saving ? 'Saving…' : 'Save & Verify'),
                  style: FilledButton.styleFrom(
                      minimumSize:
                          const Size.fromHeight(50)),
                  onPressed: canSave ? _save : null,
                ),
              ],
            ),
    );
  }
}
