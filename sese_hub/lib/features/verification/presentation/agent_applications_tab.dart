import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:sese_core/sese_core.dart';
import '../../dashboard/services/hub_pending_counts_service.dart';
import '../../../widgets/hub_badge.dart';
import 'agent_application_detail_dialog.dart';

/// Administrative review desk inside Sese Hub for Agent ("Become an Admin / Work With Us") submissions.
class AgentApplicationsTab extends StatefulWidget {
  const AgentApplicationsTab({super.key});

  @override
  State<AgentApplicationsTab> createState() => _AgentApplicationsTabState();
}

class _AgentApplicationsTabState extends State<AgentApplicationsTab> {
  final _service = AdminApplicationService();
  final _searchCtrl = TextEditingController();

  String _selectedFilter = 'All'; // 'All', 'Pending', 'Approved', 'Rejected'

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Agent Onboarding & Review Portal'),
      ),
      body: Column(
        children: [
          // Header Card
          Container(
            padding: const EdgeInsets.all(16),
            color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.admin_panel_settings_outlined, color: AppColors.seseGold),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Work With Us / Agent Applications',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  'Audit candidate Government IDs, Proof of Address, and live selfie photos. '
                  'Check hub_staff whitelisting and approve eligible candidate agent profiles.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 12),

                // Search & Filters
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _searchCtrl,
                        decoration: InputDecoration(
                          hintText: 'Search candidate name, email, or phone',
                          prefixIcon: const Icon(Icons.search, size: 20),
                          suffixIcon: _searchCtrl.text.isNotEmpty
                              ? IconButton(
                                  icon: const Icon(Icons.clear, size: 18),
                                  onPressed: () {
                                    _searchCtrl.clear();
                                    setState(() {});
                                  },
                                )
                              : null,
                          isDense: true,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),

                // Status Filter Chips
                Wrap(
                  spacing: 8,
                  children: ['All', 'Pending', 'Approved', 'Rejected'].map((filter) {
                    final selected = _selectedFilter == filter;
                    return FilterChip(
                      selected: selected,
                      label: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(filter),
                          if (filter == 'Pending')
                            HubCountBadge.stream(
                              stream: HubPendingCountsService().pendingAgentApplicationsCountStream,
                              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                              fontSize: 10,
                            ),
                        ],
                      ),
                      onSelected: (val) {
                        if (val) setState(() => _selectedFilter = filter);
                      },
                    );
                  }).toList(),
                ),
              ],
            ),
          ),

          // Submissions Stream List
          Expanded(
            child: StreamBuilder<List<AdminApplication>>(
              stream: _service.allApplicationsStream(),
              builder: (context, snap) {
                if (snap.hasError) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text('Error loading applications: ${snap.error}'),
                    ),
                  );
                }

                if (snap.connectionState == ConnectionState.waiting && !snap.hasData) {
                  return const SeseListSkeleton(itemCount: 4);
                }

                final apps = snap.data ?? [];
                final query = _searchCtrl.text.trim().toLowerCase();

                final filtered = apps.where((app) {
                  // Filter by status
                  if (_selectedFilter == 'Pending' && !app.isPending) return false;
                  if (_selectedFilter == 'Approved' && !app.isApproved) return false;
                  if (_selectedFilter == 'Rejected' && !app.isRejected) return false;

                  // Filter by search query
                  if (query.isNotEmpty) {
                    final matchName = app.fullName.toLowerCase().contains(query);
                    final matchEmail = app.email.toLowerCase().contains(query);
                    final matchPhone = app.phoneNumber.toLowerCase().contains(query);
                    return matchName || matchEmail || matchPhone;
                  }

                  return true;
                }).toList();

                if (filtered.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.inbox_outlined, size: 48, color: Colors.grey),
                        const SizedBox(height: 8),
                        Text(
                          'No agent applications match the criteria.',
                          style: TextStyle(color: Colors.grey.shade600),
                        ),
                      ],
                    ),
                  );
                }

                return ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: filtered.length,
                  itemBuilder: (context, index) {
                    final app = filtered[index];
                    return _applicationCard(context, app);
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _applicationCard(BuildContext context, AdminApplication app) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    Color statusColor;
    IconData statusIcon;

    if (app.isApproved) {
      statusColor = Colors.green;
      statusIcon = Icons.verified_user;
    } else if (app.isRejected) {
      statusColor = Colors.red;
      statusIcon = Icons.cancel;
    } else {
      statusColor = Colors.orange;
      statusIcon = Icons.hourglass_top;
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: cs.primaryContainer,
                  child: Text(
                    app.firstName.isNotEmpty ? app.firstName[0].toUpperCase() : 'A',
                    style: TextStyle(fontWeight: FontWeight.bold, color: cs.onPrimaryContainer),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        app.fullName,
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                      ),
                      Text(
                        '${app.email} • ${app.phoneNumber}',
                        style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'ID: ${app.idType.toUpperCase()} • Submitted: ${app.submittedAt.toLocal().toString().split('.').first}',
                        style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),

                // Whitelist check
                StreamBuilder<DocumentSnapshot>(
                  stream: FirebaseFirestore.instance
                      .collection('hub_staff')
                      .doc(app.email.trim().toLowerCase())
                      .snapshots(),
                  builder: (context, snap) {
                    final isWhitelisted = snap.hasData &&
                        snap.data!.exists &&
                        (snap.data!.data() as Map?)?['active'] != false;

                    return Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: isWhitelisted ? Colors.green.shade50 : Colors.amber.shade50,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: isWhitelisted ? Colors.green : Colors.amber.shade700,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            isWhitelisted ? Icons.check_circle : Icons.warning_amber,
                            size: 14,
                            color: isWhitelisted ? Colors.green : Colors.amber.shade900,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            isWhitelisted ? 'Whitelisted' : 'Not Whitelisted',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: isWhitelisted ? Colors.green.shade900 : Colors.amber.shade900,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ],
            ),
            const Divider(height: 16),

            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Chip(
                  avatar: Icon(statusIcon, size: 14, color: statusColor),
                  label: Text(
                    app.status.toUpperCase(),
                    style: TextStyle(fontSize: 11, color: statusColor, fontWeight: FontWeight.bold),
                  ),
                  backgroundColor: statusColor.withValues(alpha: 0.1),
                  visualDensity: VisualDensity.compact,
                ),

                ElevatedButton.icon(
                  onPressed: () => AgentApplicationDetailDialog.show(context, app),
                  icon: const Icon(Icons.remove_red_eye_outlined, size: 16),
                  label: const Text('Review Application'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
