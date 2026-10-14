import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:sese_core/sese_core.dart';

/// In-App Dispute & Parcel Claim Form Screen (`sese_ride`).
class DisputeOrderScreen extends StatefulWidget {
  final String orderId;
  final String userId;

  const DisputeOrderScreen({
    super.key,
    required this.orderId,
    required this.userId,
  });

  @override
  State<DisputeOrderScreen> createState() => _DisputeOrderScreenState();
}

class _DisputeOrderScreenState extends State<DisputeOrderScreen> {
  final _formKey = GlobalKey<FormState>();
  final _descriptionCtrl = TextEditingController();

  static const List<String> _reasonOptions = [
    'Item Damaged or Missing (Subject to ₦50,000 Cap)',
    'Driver Unprofessional / Wrong Route',
    'Fare Discrepancy / Overcharge',
    'Receiver Unreachable / Return Delivery Issue',
  ];

  String _selectedReason = _reasonOptions.first;
  final List<XFile> _selectedPhotos = [];
  bool _submitting = false;

  @override
  void dispose() {
    _descriptionCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickPhoto() async {
    if (_selectedPhotos.length >= 3) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Maximum 3 photos allowed.')),
      );
      return;
    }
    const service = SupportMediaService();
    final file = await service.pickPhoto();
    if (file != null && mounted) {
      setState(() => _selectedPhotos.add(file));
    }
  }

  void _removePhoto(int index) {
    setState(() => _selectedPhotos.removeAt(index));
  }

  Future<void> _submitDispute() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _submitting = true);

    try {
      final photoUrls = <String>[];
      final storage = FirebaseStorage.instance;

      for (var i = 0; i < _selectedPhotos.length; i++) {
        final photo = _selectedPhotos[i];
        final path =
            'disputes/${widget.orderId}/${DateTime.now().millisecondsSinceEpoch}_$i.jpg';
        final ref = storage.ref().child(path);
        await ref.putData(
          await photo.readAsBytes(),
          SettableMetadata(contentType: 'image/jpeg'),
        );
        final url = await ref.getDownloadURL();
        photoUrls.add(url);
      }

      final disputeId =
          'dsp_${widget.orderId.substring(0, widget.orderId.length > 8 ? 8 : widget.orderId.length)}_${DateTime.now().millisecondsSinceEpoch}';

      await FirebaseFirestore.instance
          .collection('disputes')
          .doc(disputeId)
          .set({
        'disputeId': disputeId,
        'orderId': widget.orderId,
        'tripId': widget.orderId,
        'userId': widget.userId,
        'reason': _selectedReason,
        'description': _descriptionCtrl.text.trim(),
        'photoUrls': photoUrls,
        'status': 'pending_review',
        'createdAt': FieldValue.serverTimestamp(),
      });

      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.check_circle, color: Colors.green),
              SizedBox(width: 8),
              Text('Issue Reported'),
            ],
          ),
          content: const Text(
            'Your dispute ticket has been submitted for review. Our support team will respond within 24 hours.',
          ),
          actions: [
            FilledButton(
              onPressed: () {
                Navigator.of(ctx).pop();
                Navigator.of(context).pop();
              },
              child: const Text('OK'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to submit dispute: $e'),
            backgroundColor: Colors.red.shade700,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: const SeseAppBar(title: 'Report Issue with Order'),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Order ID: ${widget.orderId}',
                style: TextStyle(
                  color: theme.textTheme.bodySmall?.color?.withValues(alpha: 0.7),
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Issue Category',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                key: const Key('dispute_reason_dropdown'),
                initialValue: _selectedReason,
                isExpanded: true,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                items: _reasonOptions
                    .map((r) => DropdownMenuItem(
                          value: r,
                          child: Text(r, style: const TextStyle(fontSize: 13)),
                        ))
                    .toList(),
                onChanged: (v) {
                  if (v != null) setState(() => _selectedReason = v);
                },
              ),
              const SizedBox(height: 20),
              const Text(
                'Description / Details',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
              ),
              const SizedBox(height: 8),
              TextFormField(
                key: const Key('dispute_description_field'),
                controller: _descriptionCtrl,
                maxLines: 4,
                decoration: const InputDecoration(
                  hintText:
                      'Provide exact details regarding lost/damaged items, driver behavior, or fare discrepancies...',
                  border: OutlineInputBorder(),
                ),
                validator: (v) {
                  if (v == null || v.trim().length < 10) {
                    return 'Please provide at least 10 characters of detail.';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Expanded(
                    child: Text(
                      'Supporting Proof (Photos)',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                      softWrap: true,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${_selectedPhotos.length}/3 photos',
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                    softWrap: false,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  ..._selectedPhotos.asMap().entries.map((entry) {
                    final idx = entry.key;
                    return Stack(
                      children: [
                        Container(
                          width: 80,
                          height: 80,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.grey.shade400),
                            color: Colors.grey.shade200,
                          ),
                          child: const Icon(Icons.image, size: 36, color: Colors.grey),
                        ),
                        Positioned(
                          top: 2,
                          right: 2,
                          child: GestureDetector(
                            onTap: () => _removePhoto(idx),
                            child: Container(
                              padding: const EdgeInsets.all(2),
                              decoration: const BoxDecoration(
                                shape: BoxShape.circle,
                                color: Colors.red,
                              ),
                              child: const Icon(Icons.close,
                                  size: 14, color: Colors.white),
                            ),
                          ),
                        ),
                      ],
                    );
                  }),
                  if (_selectedPhotos.length < 3)
                    InkWell(
                      key: const Key('add_dispute_photo_btn'),
                      onTap: _submitting ? null : _pickPhoto,
                      child: Container(
                        width: 80,
                        height: 80,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: theme.primaryColor,
                            style: BorderStyle.solid,
                          ),
                          color: theme.primaryColor.withValues(alpha: 0.1),
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.add_a_photo_outlined,
                                color: theme.primaryColor),
                            const SizedBox(height: 4),
                            Text(
                              'Add Photo',
                              style: TextStyle(
                                fontSize: 10,
                                color: theme.primaryColor,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 32),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  key: const Key('submit_dispute_btn'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.seseGold,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: _submitting ? null : _submitDispute,
                  child: _submitting
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.black,
                          ),
                        )
                      : const Text(
                          'Submit Dispute Ticket',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
