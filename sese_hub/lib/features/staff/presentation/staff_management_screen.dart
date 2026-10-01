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

class AddStaffDialogState extends State<AddStaffDialog> {
  final _formKey = GlobalKey<FormState>();
  final _emailCtrl = TextEditingController();
  UserRole _role = UserRole.agent;
  final Set<String> _permissions = {permSupportChat};
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _emailCtrl.dispose();
    super.dispose();
  }

  void _onRoleChanged(UserRole? v) {
    if (v == null) return;
    setState(() {
      _role = v;
      // staff_manage is Super-only: drop it the moment the role leaves
      // Super so it can never leak onto an Admin/Agent record.
      if (v != UserRole.superRole) {
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
      await widget.accessService.provisionStaff(
        provisionerEmail: widget.provisionerEmail,
        candidateEmail: _emailCtrl.text,
        role: _role,
        assignedPermissions: _permissions.toList(),
      );
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${_emailCtrl.text.trim().toLowerCase()} provisioned as '
            '${hubStaffRoleName(_role)}.',
          ),
          backgroundColor: Colors.green.shade800,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString().replaceFirst(RegExp(r'^[A-Za-z]+: '), '');
        _submitting = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add Staff / Provision User'),
      content: SizedBox(
        width: 420,
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
                    labelText: "Candidate's Gmail address",
                    hintText: 'name@gmail.com',
                    isDense: true,
                  ),
                  validator: (v) {
                    final t = (v ?? '').trim();
                    if (t.isEmpty) return 'Email is required';
                    if (!t.contains('@')) return 'Enter a valid email';
                    return null;
                  },
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<UserRole>(
                  initialValue: _role,
                  decoration: const InputDecoration(
                    labelText: 'Role assignment',
                    isDense: true,
                  ),
                  items: const [
                    DropdownMenuItem(
                        value: UserRole.agent, child: Text('Agent')),
                    DropdownMenuItem(
                        value: UserRole.admin, child: Text('Admin')),
                    DropdownMenuItem(
                        value: UserRole.superRole, child: Text('Super')),
                  ],
                  onChanged: _onRoleChanged,
                ),
                const SizedBox(height: 12),
                const Text(
                  'Access modules',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Tabs render only for checked modules. Staff Management '
                  'is Super-only.',
                  style: TextStyle(fontSize: 11, color: Colors.grey),
                ),
                ...hubModuleCatalog.entries.map((entry) {
                  final isStaffManage = entry.key == permStaffManage;
                  final enabled = !isStaffManage ||
                      _role == UserRole.superRole;
                  final selected =
                      _permissions.contains(entry.key) && enabled;
                  return CheckboxListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: Text(entry.value,
                        style: TextStyle(
                          fontSize: 13,
                          color: enabled ? null : Colors.grey,
                        )),
                    subtitle: isStaffManage
                        ? const Text('Super Admin only',
                            style: TextStyle(fontSize: 11))
                        : null,
                    value: selected,
                    onChanged: enabled
                        ? (v) => setState(() {
                              if (v == true) {
                                _permissions.add(entry.key);
                              } else {
                                _permissions.remove(entry.key);
                              }
                            })
                        : null,
                  );
                }),
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Text(_error!,
                      style: TextStyle(
                          color: Colors.red.shade800, fontSize: 12)),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed:
              _submitting ? null : () => Navigator.of(context).pop(),
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
          label: Text(_submitting ? 'Provisioning…' : 'Provision User'),
          onPressed: _submitting ? null : _submit,
        ),
      ],
    );
  }
}
