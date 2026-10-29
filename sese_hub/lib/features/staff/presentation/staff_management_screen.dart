import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:sese_core/sese_core.dart';
import '../../auth/hub_session_guard.dart';
import '../services/hub_access_service.dart';

/// Staff Management console. Mounted ONLY for the primary owner
/// (see [visibleTabs]): the "+ Add Staff" action and this screen are
/// never reachable by other roles — including Super-role holders — and
/// `firestore.rules` rejects non-owner writes server-side regardless.
class StaffManagementScreen extends StatefulWidget {
  final String staffEmail;
  final HubAccessService accessService;

  const StaffManagementScreen({
    super.key,
    required this.staffEmail,
    HubAccessService? accessService,
  }) : accessService = accessService ?? const _DefaultAccess();

  @override
  State<StaffManagementScreen> createState() => _StaffManagementScreenState();
}

/// Lazily constructs the production service so the widget stays
/// instantiable in tests without Firebase.
class _DefaultAccess extends HubAccessService {
  const _DefaultAccess() : super();
}

class _StaffManagementScreenState extends State<StaffManagementScreen> {
  bool get _isOwner => isPrimaryOwnerEmail(widget.staffEmail);

  @override
  void initState() {
    super.initState();
    // Force-refresh the ID token BEFORE the staff WatchStream opens.
    ensureFreshHubIdToken();
  }

  CollectionReference<Map<String, dynamic>>? get _staffCollection {
    try {
      return FirebaseFirestore.instance.collection('hub_staff');
    } catch (_) {
      return null;
    }
  }

  Future<void> _openAddStaffModal() async {
    if (!_isOwner) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AddStaffDialog(
        provisionerEmail: widget.staffEmail,
        accessService: widget.accessService,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final col = _staffCollection;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Staff Management'),
        actions: [
          if (_isOwner)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: FilledButton.icon(
                icon: const Icon(Icons.person_add_alt),
                label: const Text('Add Staff'),
                onPressed: _openAddStaffModal,
              ),
            ),
        ],
      ),
      body: col == null
          ? const Center(child: Text('Firestore unavailable.'))
          : StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: col.snapshots(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.hasError) {
                  if (isHubSessionExpiredError(snapshot.error)) {
                    return const HubSessionExpiredView(
                        contextLabel: 'staff list');
                  }
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        'Failed to load staff: ${snapshot.error}',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  );
                }
                final docs = snapshot.data?.docs ?? [];
                if (docs.isEmpty) {
                  return const Center(
                    child: Text(
                      'No provisioned staff yet.\nUse Add Staff to register the first member.',
                      textAlign: TextAlign.center,
                    ),
                  );
                }
                return ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: docs.length,
                  itemBuilder: (context, index) {
                    final record = HubStaffRecord.fromMap(docs[index].data());
                    return _StaffRow(record: record);
                  },
                );
              },
            ),
    );
  }
}

class _StaffRow extends StatelessWidget {
  final HubStaffRecord record;

  const _StaffRow({required this.record});

  @override
  Widget build(BuildContext context) {
    final role = parseHubStaffRole(record.roleRaw);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        leading: UserAvatar(displayName: record.email, radius: 20),
        title: Text(
          record.email,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                Chip(
                  label: Text(
                    role == UserRole.superRole
                        ? 'Super'
                        : role == UserRole.admin
                            ? 'Admin'
                            : 'Agent',
                    style: const TextStyle(
                        fontSize: 11, fontWeight: FontWeight.bold),
                  ),
                  visualDensity: VisualDensity.compact,
                ),
                if (!record.active)
                  const Chip(
                    label: Text('INACTIVE',
                        style: TextStyle(
                            fontSize: 11, fontWeight: FontWeight.bold)),
                    visualDensity: VisualDensity.compact,
                  ),
                // Jurisdiction scope chip (Global vs country code).
                Chip(
                  avatar: Icon(
                    record.countryScope == countryScopeGlobal
                        ? Icons.public
                        : Icons.flag_outlined,
                    size: 14,
                  ),
                  label: Text(
                    record.countryScope == countryScopeGlobal
                        ? 'Global'
                        : record.countryScope,
                    style: const TextStyle(
                        fontSize: 11, fontWeight: FontWeight.bold),
                  ),
                  visualDensity: VisualDensity.compact,
                ),
                for (final perm in record.assignedPermissions.take(4))
                  Chip(
                    label: Text(
                      hubModuleCatalog[perm] ?? perm,
                      style: const TextStyle(fontSize: 11),
                    ),
                    visualDensity: VisualDensity.compact,
                  ),
                if (record.assignedPermissions.length > 4)
                  Chip(
                    label: Text(
                        '+${record.assignedPermissions.length - 4} more',
                        style: const TextStyle(fontSize: 11)),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
            if (record.assignedBy.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Provisioned by ${record.assignedBy}',
                  style: TextStyle(
                      fontSize: 11, color: Colors.grey.shade600),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// "Add Staff / Provision User" modal: Gmail pre-authorization with
/// explicit module check-offs.
///
/// Rendered only from the owner-exclusive Staff console, and
/// [HubAccessService.provisionStaff] re-verifies the provisioner email
/// before writing — a Super-role non-owner can never reach this code
/// path, and the server rejects forged writes regardless. `staff_manage`
/// is offered for Super-role grantees only.
class AddStaffDialog extends StatefulWidget {
  final String provisionerEmail;
  final HubAccessService accessService;

  const AddStaffDialog({
    super.key,
    required this.provisionerEmail,
    required this.accessService,
  });

  @override
  State<AddStaffDialog> createState() => AddStaffDialogState();
}

enum AdminTier { superAdmin, scopedSubAdmin }

class AddStaffDialogState extends State<AddStaffDialog> {
  final _formKey = GlobalKey<FormState>();
  final _emailCtrl = TextEditingController();
  final _countryCtrl = TextEditingController();
  AdminTier _selectedTier = AdminTier.scopedSubAdmin;
  UserRole _role = UserRole.admin;
  final Set<String> _permissions = {
    permSupportChat,
    permEditFares,
    permP2pLimits,
  };

  /// Jurisdiction scope: true = Global, false = specific country code.
  bool _scopeIsGlobal = true;
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _emailCtrl.dispose();
    _countryCtrl.dispose();
    super.dispose();
  }

  void _onTierChanged(AdminTier tier) {
    setState(() {
      _selectedTier = tier;
      if (tier == AdminTier.superAdmin) {
        _role = UserRole.superRole;
        _permissions.addAll(hubModuleCatalog.keys);
      } else {
        _role = UserRole.admin;
        _permissions.remove(permStaffManage);
      }
    });
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final finalPerms = _selectedTier == AdminTier.superAdmin
          ? hubModuleCatalog.keys.toList()
          : _permissions.toList();
      final scope = _scopeIsGlobal
          ? countryScopeGlobal
          : normalizeCountryScope(_countryCtrl.text);

      await widget.accessService.provisionStaff(
        provisionerEmail: widget.provisionerEmail,
        candidateEmail: _emailCtrl.text,
        role: _role,
        assignedPermissions: finalPerms,
        countryScope: scope,
      );
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${_emailCtrl.text.trim().toLowerCase()} provisioned as '
            '${_selectedTier == AdminTier.superAdmin ? "Super Admin" : "Scoped Sub-Admin"}.',
          ),
          backgroundColor: Colors.green.shade800,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      debugPrint('StaffManagementDialog error: $e');
      setState(() {
        _error =
            'Unable to provision staff member. Please check details and try again.';
        _submitting = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      // 16px insets keep the form edge-to-edge on phones (the default 40
      // insets + fixed content left a narrow column).
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      title: const Text('Add Admin / Provision Staff'),
      // double.infinity (not fixed 460) so the form spans the dialog on
      // phones instead of overflowing a narrow viewport; the dialog's
      // own constraints cap it on wide screens.
      content: SizedBox(
        width: double.infinity,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextFormField(
                  controller: _emailCtrl,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(
                    labelText: "Admin's Email address",
                    hintText: 'admin@sesetech.com',
                    isDense: true,
                    prefixIcon: Icon(Icons.email_outlined),
                  ),
                  validator: (v) {
                    final t = (v ?? '').trim();
                    if (t.isEmpty) return 'Email is required';
                    if (!t.contains('@')) return 'Enter a valid email';
                    return null;
                  },
                ),
                const SizedBox(height: 16),
                const Text(
                  'Admin Tier Assignment',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                ),
                const SizedBox(height: 8),
                SegmentedButton<AdminTier>(
                  segments: const [
                    ButtonSegment<AdminTier>(
                      value: AdminTier.superAdmin,
                      label: Text('Super Admin'),
                      icon: Icon(Icons.security),
                    ),
                    ButtonSegment<AdminTier>(
                      value: AdminTier.scopedSubAdmin,
                      label: Text('Scoped Sub-Admin'),
                      icon: Icon(Icons.admin_panel_settings_outlined),
                    ),
                  ],
                  selected: {_selectedTier},
                  onSelectionChanged: (Set<AdminTier> newSelection) {
                    _onTierChanged(newSelection.first);
                  },
                ),
                const SizedBox(height: 16),
                if (_selectedTier == AdminTier.superAdmin) ...[
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.amber.shade50,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.amber.shade300),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.star, color: Colors.amber.shade800),
                        const SizedBox(width: 8),
                        const Expanded(
                          child: Text(
                            'Super Admin tier automatically grants full system permissions across all modules.',
                            style: TextStyle(fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                  ),
                ] else ...[
                  const Text(
                    'Scoped Permissions Checklist',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Select specific modules and administrative actions allowed for this Sub-Admin.',
                    style: TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                  const SizedBox(height: 8),
                  ...hubModuleCatalog.entries
                      .where((entry) => entry.key != permStaffManage)
                      .map((entry) {
                    final selected = _permissions.contains(entry.key);
                    return CheckboxListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      title: Text(
                        entry.value,
                        style: const TextStyle(fontSize: 13),
                      ),
                      value: selected,
                      onChanged: (v) => setState(() {
                        if (v == true) {
                          _permissions.add(entry.key);
                        } else {
                          _permissions.remove(entry.key);
                        }
                      }),
                    );
                  }),
                ],
                const SizedBox(height: 16),
                const Text(
                  'Sub-Section Permissions',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Optional fine-grained grants inside modules (e.g. Pricing '
                  'without API keys). Leave all unchecked to allow every '
                  'section under the granted modules (legacy behavior).',
                  style: TextStyle(fontSize: 11, color: Colors.grey),
                ),
                const SizedBox(height: 8),
                ...hubSectionCatalog.entries.map((entry) {
                  final selected = _permissions.contains(entry.key);
                  return CheckboxListTile(
                    dense: true,
                    contentPadding:
                        const EdgeInsets.only(left: 12),
                    controlAffinity: ListTileControlAffinity.leading,
                    title: Text(
                      entry.value,
                      style: const TextStyle(fontSize: 13),
                    ),
                    value: selected,
                    onChanged: (v) => setState(() {
                      if (v == true) {
                        _permissions.add(entry.key);
                      } else {
                        _permissions.remove(entry.key);
                      }
                    }),
                  );
                }),
                const SizedBox(height: 16),
                const Text(
                  'Jurisdiction Scope',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Global sees every country. A specific scope locks data '
                  'views (Active Rides today) to that country code.',
                  style: TextStyle(fontSize: 11, color: Colors.grey),
                ),
                const SizedBox(height: 8),
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment<bool>(
                      value: true,
                      label: Text('Global'),
                      icon: Icon(Icons.public),
                    ),
                    ButtonSegment<bool>(
                      value: false,
                      label: Text('Specific Country'),
                      icon: Icon(Icons.flag_outlined),
                    ),
                  ],
                  selected: {_scopeIsGlobal},
                  onSelectionChanged: (s) =>
                      setState(() => _scopeIsGlobal = s.first),
                ),
                if (!_scopeIsGlobal) ...[
                  const SizedBox(height: 8),
                  TextFormField(
                    controller: _countryCtrl,
                    textCapitalization: TextCapitalization.characters,
                    decoration: const InputDecoration(
                      labelText: 'Country Code (ISO, e.g. NG)',
                      isDense: true,
                      prefixIcon: Icon(Icons.flag_outlined),
                    ),
                    validator: (v) {
                      if (_scopeIsGlobal) return null;
                      if ((v ?? '').trim().isEmpty) {
                        return 'Enter a country code or switch to Global';
                      }
                      return null;
                    },
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    style: TextStyle(color: Colors.red.shade800, fontSize: 12),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          icon: _submitting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white))
              : const Icon(Icons.person_add_alt),
          label: Text(_submitting ? 'Provisioning…' : 'Provision Admin'),
          onPressed: _submitting ? null : _submit,
        ),
      ],
    );
  }
}
