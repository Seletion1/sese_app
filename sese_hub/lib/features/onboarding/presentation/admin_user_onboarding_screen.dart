import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import '../services/hub_onboarding_service.dart';
import 'widgets/onboarding_wizard_dialog.dart';

/// Admin-Assisted Onboarding and Registration Console inside `sese_hub`.
class AdminUserOnboardingScreen extends StatefulWidget {
  const AdminUserOnboardingScreen({super.key});

  @override
  State<AdminUserOnboardingScreen> createState() => _AdminUserOnboardingScreenState();
}

class _AdminUserOnboardingScreenState extends State<AdminUserOnboardingScreen> {
  final _service = HubOnboardingService();
  final _searchCtrl = TextEditingController();
  
  bool _isSearching = false;
  String? _searchError;
  OnboardingLookupResult? _searchResult;

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _performSearch() async {
    final query = _searchCtrl.text.trim();
    if (query.isEmpty) return;

    setState(() {
      _isSearching = true;
      _searchError = null;
      _searchResult = null;
    });

    try {
      final res = await _service.lookupAccount(query);
      setState(() {
        _searchResult = res;
      });
    } catch (e) {
      debugPrint('AdminUserOnboarding lookup error: $e');
      setState(() {
        _searchError =
            'Unable to lookup account. Please check the identifier and try again.';
      });
    } finally {
      setState(() {
        _isSearching = false;
      });
    }
  }

  Future<void> _openRegistrationWizard({String? initialIdentifier, OnboardingLookupResult? lookupResult}) async {
    final success = await OnboardingWizardDialog.show(
      context,
      initialIdentifier: initialIdentifier,
      lookupResult: lookupResult,
    );

    if (success == true && mounted) {
      _searchCtrl.clear();
      setState(() {
        _searchResult = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('User & Driver Onboarding Console'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Single cohesive header banner: description + the one Register
            // CTA live together, so there is no AppBar button competing with
            // the card and no double-tap confusion. Stacks vertically on
            // narrow phones (same <520 breakpoint as the result cards).
            Card(
              color: theme.colorScheme.primaryContainer.withValues(alpha: 0.4),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final header = Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.admin_panel_settings,
                            size: 36, color: theme.colorScheme.primary),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Text(
                                'Admin-Assisted Registration & Provisioning',
                                style: TextStyle(
                                    fontWeight: FontWeight.bold, fontSize: 16),
                                softWrap: true,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Search existing profiles to resume onboarding or initiate a new user/driver registration with live photo verification and Self-Verification Lock.',
                                style: TextStyle(
                                    color: theme
                                        .colorScheme.onSurfaceVariant,
                                    fontSize: 13),
                                softWrap: true,
                              ),
                            ],
                          ),
                        ),
                      ],
                    );
                    final cta = FilledButton.icon(
                      key: const Key('register_new_user_button'),
                      onPressed: () => _openRegistrationWizard(),
                      icon: const Icon(Icons.person_add_alt_1),
                      label: const Text('Register New User / Driver'),
                    );
                    if (constraints.maxWidth < 520) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          header,
                          const SizedBox(height: 12),
                          cta,
                        ],
                      );
                    }
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(child: header),
                        const SizedBox(width: 12),
                        Flexible(child: cta),
                      ],
                    );
                  },
                ),
              ),
            ),
            const SizedBox(height: 24),

            // Search Bar — stacks vertically on narrow phones so the input
            // keeps a usable width instead of squeezing beside the button.
            LayoutBuilder(
              builder: (context, constraints) {
                final isNarrow = constraints.maxWidth < 420;
                final searchField = TextField(
                  controller: _searchCtrl,
                  decoration: InputDecoration(
                    hintText: 'Search by phone or email',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _searchCtrl.text.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear),
                            onPressed: () {
                              _searchCtrl.clear();
                              setState(() => _searchResult = null);
                            },
                          )
                        : null,
                    border: const OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _performSearch(),
                );
                final searchButton = ElevatedButton.icon(
                  onPressed: _isSearching ? null : _performSearch,
                  icon: _isSearching
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.search),
                  label: const Text('Search'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                  ),
                );
                if (isNarrow) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      searchField,
                      const SizedBox(height: 8),
                      searchButton,
                    ],
                  );
                }
                return Row(
                  children: [
                    Expanded(child: searchField),
                    const SizedBox(width: 12),
                    searchButton,
                  ],
                );
              },
            ),
            const SizedBox(height: 20),

            if (_searchError != null)
              Container(
                padding: const EdgeInsets.all(12),
                color: Colors.red.shade50,
                child: Text(_searchError!, style: TextStyle(color: Colors.red.shade900)),
              ),

            // Search Result Card
            if (_searchResult != null) _buildSearchResultCard(_searchResult!),

            const SizedBox(height: 28),
            const Text(
              'Recent Profiles Pending Onboarding Verification',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),

            // Realtime Stream of Pending Users
            StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('users')
                  .where('customerVerificationStatus', isEqualTo: 'pending')
                  .limit(10)
                  .snapshots(),
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return Text('Error loading pending users: ${snapshot.error}');
                }
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }

                final docs = snapshot.data!.docs;
                if (docs.isEmpty) {
                  return Container(
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade100,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Center(
                      child: Text('No pending user onboarding records requiring review.'),
                    ),
                  );
                }

                return Column(
                  children: docs.map((doc) {
                    final data = doc.data() as Map<String, dynamic>;
                    final name = data['fullName']?.toString() ?? 'Unnamed Profile';
                    final phone = data['phoneNumber']?.toString() ?? '';
                    final role = data['role']?.toString() ?? 'customer';
                    final adminId = data['createdByAdminId']?.toString();

                    return Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        leading: CircleAvatar(
                          child: Icon(role == 'driver' ? Icons.directions_car : Icons.person),
                        ),
                        title: Text(
                          name,
                          style: const TextStyle(fontWeight: FontWeight.bold),
                          softWrap: true,
                        ),
                        subtitle: Text(
                          '$phone • Role: ${role.toUpperCase()}\n${adminId != null ? "Created by Admin: $adminId" : "Self-Registered"}',
                          softWrap: true,
                        ),
                        isThreeLine: true,
                        trailing: ElevatedButton(
                          onPressed: () {
                            _openRegistrationWizard(
                              initialIdentifier: phone,
                              lookupResult: OnboardingLookupResult(
                                exists: true,
                                uid: doc.id,
                                role: role,
                                userData: data,
                              ),
                            );
                          },
                          style: ElevatedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                            visualDensity: VisualDensity.compact,
                          ),
                          child: const Text(
                            'Resume / Edit',
                            style: TextStyle(fontSize: 12),
                            softWrap: false,
                            overflow: TextOverflow.visible,
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchResultCard(OnboardingLookupResult result) {
    if (!result.exists) {
      return Card(
        color: Colors.green.shade50,
        child: Padding(
          padding: const EdgeInsets.all(16),
          // LayoutBuilder stacks the CTA below the text on narrow phones.
          // In a single Row the button steals most of the width, squeezing
          // the Expanded text to ~60px so words break letter-by-letter.
          child: LayoutBuilder(
            builder: (context, constraints) {
              final header = Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.person_add, color: Colors.green, size: 32),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          'No existing account found',
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                          softWrap: true,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          result.message ?? 'This phone or email is available for new registration.',
                          softWrap: true,
                        ),
                      ],
                    ),
                  ),
                ],
              );
              final cta = ElevatedButton.icon(
                onPressed: () => _openRegistrationWizard(
                  initialIdentifier: _searchCtrl.text.trim(),
                  lookupResult: result,
                ),
                icon: const Icon(Icons.add),
                label: const Text('Start Registration'),
              );
              if (constraints.maxWidth < 520) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    header,
                    const SizedBox(height: 12),
                    cta,
                  ],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(child: header),
                  const SizedBox(width: 12),
                  Flexible(child: cta),
                ],
              );
            },
          ),
        ),
      );
    }

    final u = result.userData ?? {};
    return Card(
      color: Colors.blue.shade50,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LayoutBuilder(
              builder: (context, constraints) {
                final header = Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.account_box, color: Colors.blue, size: 32),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            u['fullName']?.toString() ?? 'Existing User',
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                            softWrap: true,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '${u['phoneNumber'] ?? ''} • ${u['email'] ?? ''}',
                            softWrap: true,
                          ),
                        ],
                      ),
                    ),
                  ],
                );
                final cta = ElevatedButton.icon(
                  onPressed: () => _openRegistrationWizard(
                    initialIdentifier: _searchCtrl.text.trim(),
                    lookupResult: result,
                  ),
                  icon: const Icon(Icons.edit),
                  label: const Text('Resume Onboarding'),
                );
                if (constraints.maxWidth < 520) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      header,
                      const SizedBox(height: 12),
                      cta,
                    ],
                  );
                }
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(child: header),
                    const SizedBox(width: 12),
                    Flexible(child: cta),
                  ],
                );
              },
            ),
            if (result.missingSteps.isNotEmpty) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                children: result.missingSteps.map((step) {
                  return Chip(
                    avatar: const Icon(Icons.warning_amber, size: 16, color: Colors.orange),
                    label: Text(step, style: const TextStyle(fontSize: 12)),
                    backgroundColor: Colors.orange.shade100,
                  );
                }).toList(),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
