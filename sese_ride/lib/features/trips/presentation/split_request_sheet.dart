import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sese_core/sese_core.dart';

/// Split-payment request sheet (trip customer only).
///
/// Collects 1–5 co-payer phone numbers and creates the split intent. The
/// server resolves each number (registered, KYC-verified accounts only),
/// computes equal shares that sum exactly to the fare (the requester absorbs
/// rounding dust), and notifies every co-payer with an authenticated prompt.
/// Money moves only after EVERYONE accepts, atomically server-side — and a
/// decline anywhere leaves the full fare with the requester.
class SplitRequestSheet extends StatefulWidget {
  final String tripId;

  /// Test seam.
  final SplitService? service;

  const SplitRequestSheet({
    super.key,
    required this.tripId,
    this.service,
  });

  static Future<String?> show(
    BuildContext context, {
    required String tripId,
    SplitService? service,
  }) {
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => SplitRequestSheet(tripId: tripId, service: service),
    );
  }

  @override
  State<SplitRequestSheet> createState() => _SplitRequestSheetState();
}

class _SplitRequestSheetState extends State<SplitRequestSheet> {
  late final SplitService _service = widget.service ?? const SplitService();

  final List<TextEditingController> _phones = [TextEditingController()];
  final _formKey = GlobalKey<FormState>();
  bool _submitting = false;

  @override
  void dispose() {
    for (final c in _phones) {
      c.dispose();
    }
    super.dispose();
  }

  void _addField() {
    if (_phones.length >= 5) return;
    setState(() => _phones.add(TextEditingController()));
  }

  void _removeField(int i) {
    if (_phones.length <= 1) return;
    setState(() {
      _phones[i].dispose();
      _phones.removeAt(i);
    });
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final phones =
        _phones.map((c) => c.text.trim()).where((t) => t.isNotEmpty).toList();
    if (phones.isEmpty) return;

    setState(() => _submitting = true);
    try {
      final splitId = await _service.requestSplit(
        tripId: widget.tripId,
        copayerPhones: phones,
      );
      if (!mounted) return;
      Navigator.of(context).pop(splitId);
    } on SplitException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message)),
      );
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // 16px gutters so inputs + the request bar span edge-to-edge.
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 4,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Row(
                children: [
                  Icon(Icons.group_add_outlined),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Split Fare',
                      style: TextStyle(
                          fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              const Text(
                'Invite up to 5 verified SeSe users to share this fare '
                'equally. Everyone gets an authenticated prompt; shares '
                'move only after all accept — a decline leaves the full '
                'fare with you.',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
              const SizedBox(height: 16),
              for (var i = 0; i < _phones.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextFormField(
                          key: Key('split_phone_field_$i'),
                          controller: _phones[i],
                          keyboardType: TextInputType.phone,
                          inputFormatters: [
                            FilteringTextInputFormatter.allow(
                                RegExp(r'[0-9+\s]')),
                          ],
                          decoration: InputDecoration(
                            labelText: 'Co-payer ${i + 1} phone',
                            hintText: '08012345678',
                            border: const OutlineInputBorder(),
                          ),
                          validator: (value) {
                            final digits = (value ?? '')
                                .replaceAll(RegExp(r'\D'), '');
                            if (digits.isEmpty && _phones.length > 1) {
                              return null;
                            }
                            if (digits.length < 10) {
                              return 'Enter a valid phone number.';
                            }
                            return null;
                          },
                        ),
                      ),
                      if (_phones.length > 1)
                        IconButton(
                          tooltip: 'Remove',
                          icon: const Icon(Icons.remove_circle_outline),
                          onPressed: () => _removeField(i),
                        ),
                    ],
                  ),
                ),
              if (_phones.length < 5)
                TextButton.icon(
                  key: const Key('split_add_phone_button'),
                  icon: const Icon(Icons.add),
                  label: const Text('Add another co-payer'),
                  onPressed: _addField,
                ),
              const SizedBox(height: 8),
              FilledButton.icon(
                key: const Key('split_submit_button'),
                icon: _submitting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.send),
                label:
                    Text(_submitting ? 'Sending invites…' : 'Send Invites'),
                onPressed: _submitting ? null : _submit,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
