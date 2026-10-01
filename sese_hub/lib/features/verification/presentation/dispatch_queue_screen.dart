import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../auth/hub_session_guard.dart';

/// Queue Inspector: live monitor for the cascading dispatch engine.
///
/// Streams every trip currently inside dispatch (SEARCHING_DRIVER,
/// WAITING_FOR_ACCEPTANCE, MARKETPLACE_OPEN, MARKETPLACE_LIST) and renders
/// per-order stage, ping targets, retry counters, tier deadlines, fares,
/// and expandable pending bids. Read-only — dispatch itself stays
/// server-authoritative (tunables live in the Dispatch Console).
class DispatchQueueTab extends StatelessWidget {
  final FirebaseFirestore? firestore;

  const DispatchQueueTab({super.key, this.firestore});

  FirebaseFirestore get _db {
    try {
      return firestore ?? FirebaseFirestore.instance;
    } catch (_) {
      return firestore!;
    }
  }

  static const _stages = [
    'SEARCHING_DRIVER',
    'WAITING_FOR_ACCEPTANCE',
    'MARKETPLACE_OPEN',
    'MARKETPLACE_LIST',
  ];

  Stream<QuerySnapshot<Map<String, dynamic>>> _queueStream() {
    return _db
        .collection('trips')
        .where('status', whereIn: _stages)
        .limit(50)
        .snapshots();
  }

  @override
  Widget build(BuildContext context) {
    FirebaseFirestore? db;
    try {
      db = _db;
    } catch (_) {
      db = null;
    }
    if (db == null) {
      return const Center(child: Text('Firestore unavailable.'));
    }
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: _queueStream(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting &&
            !snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          if (isHubSessionExpiredError(snapshot.error)) {
            return const HubSessionExpiredView(
                contextLabel: 'dispatch queue');
          }
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text('Failed to load dispatch queue: ${snapshot.error}',
                  textAlign: TextAlign.center),
            ),
          );
        }
        final docs = (snapshot.data?.docs ?? []).toList()
          ..sort((a, b) {
            final at = _millis(a.data()['updatedAt']) ??
                _millis(a.data()['createdAt']) ??
                0;
            final bt = _millis(b.data()['updatedAt']) ??
                _millis(b.data()['createdAt']) ??
                0;
            return bt.compareTo(at);
          });
        if (docs.isEmpty) {
          return const Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.check_circle_outline, size: 64, color: Colors.green),
                SizedBox(height: 16),
                Text('Dispatch queue clear — no live orders.'),
              ],
            ),
          );
        }
        final counts = <String, int>{};
        for (final d in docs) {
          final s = (d.data()['status'] ?? '').toString();
          counts[s] = (counts[s] ?? 0) + 1;
        }
        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: docs.length + 1,
          itemBuilder: (context, index) {
            if (index == 0) return _StageSummary(counts);
            return _QueueCard(
              db: db!,
              docId: docs[index - 1].id,
              data: docs[index - 1].data(),
            );
          },
        );
      },
    );
  }

  static int? _millis(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toInt();
    try {
      final d = (v as dynamic).toDate();
      if (d is DateTime) return d.millisecondsSinceEpoch;
    } catch (_) {}
    if (v is String) return DateTime.tryParse(v)?.millisecondsSinceEpoch;
    return null;
  }
}

class _StageSummary extends StatelessWidget {
  final Map<String, int> counts;

  const _StageSummary(this.counts);

  @override
  Widget build(BuildContext context) {
    final total = counts.values.fold<int>(0, (a, b) => a + b);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            Chip(
              avatar: const Icon(Icons.queue, size: 16),
              label: Text('Live orders: $total',
                  style: const TextStyle(fontWeight: FontWeight.bold)),
            ),
            for (final e in counts.entries)
              Chip(label: Text('${e.key}: ${e.value}')),
          ],
        ),
      ),
    );
  }
}

class _QueueCard extends StatefulWidget {
  final FirebaseFirestore db;
  final String docId;
  final Map<String, dynamic> data;

  const _QueueCard({
    required this.db,
    required this.docId,
    required this.data,
  });

  @override
  State<_QueueCard> createState() => _QueueCardState();
}

class _QueueCardState extends State<_QueueCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final d = widget.data;
    final status = (d['status'] ?? '').toString();
    final tier = (d['dispatchTier'] as num?)?.toInt();
    final decline = (d['declineCount'] as num?)?.toInt() ?? 0;
    final recycles = (d['recycleCount'] as num?)?.toInt() ?? 0;
    final reassigns = (d['reassignmentCount'] as num?)?.toInt() ?? 0;
    final pingOne = (d['pingDriverId'] ?? '').toString();
    final pingGroup = ((d['pingDriverIds']) as List<dynamic>?)
            ?.map((e) => e.toString())
            .toList() ??
        const [];
    final fare = (d['fareFormatted'] ?? '').toString().isNotEmpty
        ? (d['fareFormatted'] ?? '').toString()
        : '₦${((d['fareAmount'] as num?) ?? 0).toStringAsFixed(0)}';
    final hasBids = d['hasActiveBids'] == true;
    final pickup = ((d['pickup'] as Map?)?['address'] ?? '').toString();
    final expiresAt = (d['tierExpiresAt'] as num?)?.toInt();
    final updated = DispatchQueueTab._millis(d['updatedAt']);

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Trip ${widget.docId.length > 8 ? widget.docId.substring(0, 8) : widget.docId}…',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                Chip(
                  label: Text(status,
                      style: const TextStyle(
                          fontSize: 11, fontWeight: FontWeight.bold)),
                  backgroundColor: status == 'MARKETPLACE_LIST'
                      ? Colors.purple.shade100
                      : Colors.orange.shade100,
                ),
              ],
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                if (tier != null) Chip(label: Text('Stage $tier')),
                Chip(label: Text('Retries: $decline')),
                if (recycles > 0) Chip(label: Text('Recycles: $recycles')),
                if (reassigns > 0) Chip(label: Text('Reassigns: $reassigns')),
                if (hasBids)
                  Chip(
                    avatar: const Icon(Icons.gavel,
                        size: 14, color: Colors.white),
                    label: const Text('Pending bids',
                        style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 11)),
                    backgroundColor: Colors.blue.shade700,
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text('Fare: $fare',
                style: const TextStyle(fontWeight: FontWeight.w600)),
            if (pickup.isNotEmpty)
              Text('Pickup: $pickup',
                  style:
                      const TextStyle(fontSize: 12, color: Colors.black54)),
            if (pingOne.isNotEmpty)
              Text('Ping target: $pingOne',
                  style: const TextStyle(fontSize: 12)),
            if (pingGroup.isNotEmpty)
              Text('Ping group (${pingGroup.length}): ${pingGroup.join(', ')}',
                  style: const TextStyle(fontSize: 12)),
            if (expiresAt != null)
              Text(_deadlineLabel(expiresAt),
                  style: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w600)),
            if (updated != null)
              Text(
                'Updated: ${DateTime.fromMillisecondsSinceEpoch(updated).toLocal()}',
                style:
                    const TextStyle(fontSize: 11, color: Colors.black45),
              ),
            TextButton.icon(
              icon: Icon(_expanded ? Icons.expand_less : Icons.expand_more),
              label: Text(_expanded ? 'Hide bids' : 'Inspect pending bids'),
              onPressed: () => setState(() => _expanded = !_expanded),
            ),
            if (_expanded) _PendingBids(db: widget.db, tripId: widget.docId),
          ],
        ),
      ),
    );
  }

  String _deadlineLabel(int expiresAtMs) {
    final remaining =
        Duration(milliseconds: expiresAtMs - DateTime.now().millisecondsSinceEpoch);
    if (remaining.isNegative) return 'Stage deadline: expired — sweep promoting';
    return 'Stage deadline: ${remaining.inSeconds}s remaining';
  }
}

class _PendingBids extends StatelessWidget {
  final FirebaseFirestore db;
  final String tripId;

  const _PendingBids({required this.db, required this.tripId});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<QuerySnapshot<Map<String, dynamic>>>(
      future: db
          .collection('trips')
          .doc(tripId)
          .collection('bids')
          .where('status', isEqualTo: 'pending')
          .get(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.all(8),
            child: Center(
                child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))),
          );
        }
        if (snapshot.hasError) {
          return Text('Could not load bids: ${snapshot.error}',
              style: const TextStyle(fontSize: 12, color: Colors.red));
        }
        final bids = snapshot.data?.docs ?? [];
        if (bids.isEmpty) {
          return const Text('No pending bids on this trip.',
              style: TextStyle(fontSize: 12, color: Colors.grey));
        }
        return Column(
          children: bids.map((b) {
            final m = b.data();
            final fare = (m['offeredFare'] as num?)?.toStringAsFixed(0) ?? '—';
            return ListTile(
              dense: true,
              leading: const Icon(Icons.gavel, size: 18),
              title: Text(
                  '${m['driverName'] ?? b.id} — ₦$fare (${m['etaMinutes'] ?? '?'} min ETA)'),
              subtitle: Text('Rating: ${m['rating'] ?? '—'}',
                  style: const TextStyle(fontSize: 11)),
            );
          }).toList(),
        );
      },
    );
  }
}
