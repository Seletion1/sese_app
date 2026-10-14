import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:sese_core/sese_core.dart';

/// "Send Notification" admin module (Hub → Broadcasts tab).
///
/// RBAC: the tab is only visible to Super Admins and staffers holding the
/// `broadcast_notifications` grant; `sendTargetedBroadcast` re-validates
/// server-side, so hiding the tab is UX-only depth.
class BroadcastScreen extends StatefulWidget {
  const BroadcastScreen({super.key});

  @override
  State<BroadcastScreen> createState() => _BroadcastScreenState();
}

enum _Audience { all, customers, drivers }

enum _Scope { global, country, state }

enum _TargetMode { segment, userIds, global }

class _BroadcastScreenState extends State<BroadcastScreen> {
  final _titleCtrl = TextEditingController();
  final _bodyCtrl = TextEditingController();
  final _userIdsCtrl = TextEditingController();

  _Audience _audience = _Audience.all;
  _Scope _scope = _Scope.global;
  String? _countryCode;
  String? _state;
  VehicleCategory? _vehicle;
  _TargetMode _mode = _TargetMode.segment;

  bool _sending = false;
  String? _result;

  @override
  void dispose() {
    _titleCtrl.dispose();
    _bodyCtrl.dispose();
    _userIdsCtrl.dispose();
    super.dispose();
  }

  List<String> get _statesForCountry {
    final code = _countryCode;
    if (code == null || code.isEmpty) return const [];
    return kCountryToStatesMap[code.toUpperCase()] ?? const [];
  }

  Future<void> _send() async {
    final title = _titleCtrl.text.trim();
    final body = _bodyCtrl.text.trim();
    if (title.isEmpty || body.isEmpty) {
      setState(() => _result = 'Title and message body are required.');
      return;
    }
    List<String> userIds = const [];
    if (_mode == _TargetMode.userIds) {
      userIds = _userIdsCtrl.text
          .split(RegExp(r'[\s,;]+'))
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();
      if (userIds.isEmpty) {
        setState(() => _result = 'Enter at least one user ID.');
        return;
      }
    }
    setState(() {
      _sending = true;
      _result = null;
    });
    try {
      final callable =
          FirebaseFunctions.instance.httpsCallable('sendTargetedBroadcast');
      final res = await callable.call({
        'title': title,
        'body': body,
        'audience': _audience.name,
        'mode': _mode.name,
        'userIds': userIds,
        'country': _scope == _Scope.global ? null : _countryCode,
        'state': _scope == _Scope.state ? _state : null,
        'vehicleCategory': _vehicle?.name,
      });
      final data = Map<String, dynamic>.from(res.data as Map);
      if (!mounted) return;
      setState(() {
        _result = 'Broadcast queued: ${data['targeted'] ?? 0} targeted, '
            '${data['notified'] ?? 0} notified'
            '${(data['failed'] ?? 0) != 0 ? ', ${data['failed']} failed' : ''}.';
      });
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      setState(() => _result = 'Send failed (${e.code}): ${e.message}');
    } catch (e) {
      if (!mounted) return;
      setState(() => _result = 'Send failed: $e');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final countries = SeseCountryCatalog.allCountries;
    return Scaffold(
      appBar: AppBar(title: const Text('Send Notification')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const Key('broadcast_title'),
              controller: _titleCtrl,
              decoration: const InputDecoration(
                labelText: 'Title',
                border: OutlineInputBorder(),
              ),
              maxLength: 80,
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('broadcast_body'),
              controller: _bodyCtrl,
              decoration: const InputDecoration(
                labelText: 'Message Body',
                border: OutlineInputBorder(),
              ),
              maxLines: 4,
              maxLength: 500,
            ),
            const SizedBox(height: 16),
            const Text('Audience Role',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            SegmentedButton<_Audience>(
              segments: const [
                ButtonSegment(value: _Audience.all, label: Text('All')),
                ButtonSegment(
                    value: _Audience.customers, label: Text('Customers')),
                ButtonSegment(
                    value: _Audience.drivers, label: Text('Drivers')),
              ],
              selected: {_audience},
              onSelectionChanged: (s) => setState(() => _audience = s.first),
            ),
            const SizedBox(height: 16),
            const Text('Geographic Scope',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            SegmentedButton<_Scope>(
              segments: const [
                ButtonSegment(value: _Scope.global, label: Text('Global')),
                ButtonSegment(value: _Scope.country, label: Text('Country')),
                ButtonSegment(value: _Scope.state, label: Text('State')),
              ],
              selected: {_scope},
              onSelectionChanged: (s) => setState(() {
                _scope = s.first;
                if (_scope == _Scope.global) {
                  _countryCode = null;
                  _state = null;
                }
              }),
            ),
            if (_scope != _Scope.global) ...[
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                key: const Key('broadcast_country'),
                initialValue: _countryCode,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Country',
                  border: OutlineInputBorder(),
                ),
                items: [
                  for (final c in countries)
                    DropdownMenuItem(
                      value: c.countryCode,
                      child: Text(
                        c.displayName,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (v) => setState(() {
                  _countryCode = v;
                  _state = null;
                }),
              ),
            ],
            if (_scope == _Scope.state) ...[
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                key: const Key('broadcast_state'),
                initialValue: _state,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'State',
                  border: OutlineInputBorder(),
                ),
                items: [
                  for (final st in _statesForCountry)
                    DropdownMenuItem(
                      value: st,
                      child: Text(st, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: _statesForCountry.isEmpty
                    ? null
                    : (v) => setState(() => _state = v),
              ),
              if ((_countryCode ?? '').isNotEmpty &&
                  _statesForCountry.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 6),
                  child: Text(
                    'No stored state list for this country — state filtering '
                    'will match users that saved one.',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ),
            ],
            if (_audience != _Audience.customers) ...[
              const SizedBox(height: 16),
              const Text('Vehicle Type Filter (Drivers)',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              DropdownButtonFormField<VehicleCategory?>(
                key: const Key('broadcast_vehicle'),
                initialValue: _vehicle,
                decoration: const InputDecoration(
                  labelText: 'Vehicle',
                  border: OutlineInputBorder(),
                ),
                items: [
                  const DropdownMenuItem(
                      value: null, child: Text('All Vehicles')),
                  for (final v in VehicleCategory.values)
                    DropdownMenuItem(
                        value: v, child: Text(v.displayName)),
                ],
                onChanged: (v) => setState(() => _vehicle = v),
              ),
            ],
            const SizedBox(height: 16),
            const Text('Targeting Mode',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            SegmentedButton<_TargetMode>(
              segments: const [
                ButtonSegment(
                    value: _TargetMode.segment, label: Text('Segment')),
                ButtonSegment(
                    value: _TargetMode.userIds, label: Text('User IDs')),
                ButtonSegment(value: _TargetMode.global, label: Text('Global')),
              ],
              selected: {_mode},
              onSelectionChanged: (s) => setState(() => _mode = s.first),
            ),
            if (_mode == _TargetMode.userIds) ...[
              const SizedBox(height: 12),
              TextField(
                key: const Key('broadcast_user_ids'),
                controller: _userIdsCtrl,
                decoration: const InputDecoration(
                  labelText: 'User IDs (comma / space separated)',
                  border: OutlineInputBorder(),
                ),
                maxLines: 3,
              ),
            ],
            if (_mode == _TargetMode.global)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'Global ignores role, geography, and vehicle filters.',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ),
            const SizedBox(height: 20),
            FilledButton.icon(
              key: const Key('broadcast_send'),
              onPressed: _sending ? null : _send,
              icon: _sending
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child:
                          CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.campaign_outlined),
              label: Text(_sending ? 'Sending…' : 'Send Broadcast'),
            ),
            if (_result != null) ...[
              const SizedBox(height: 12),
              Text(_result!, style: const TextStyle(fontSize: 13)),
            ],
          ],
        ),
      ),
    );
  }
}
