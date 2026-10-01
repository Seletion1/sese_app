import 'package:flutter/material.dart';

/// Full-screen lock shown when `in_maintenance_mode` is true.
///
/// Deliberately offers no dismiss affordance: the only exit is a Remote Config
/// publish flipping the flag back to false, which the live
/// `onConfigUpdated` listener picks up and rebuilds the gate.
class MaintenanceScreen extends StatelessWidget {
  final String message;

  const MaintenanceScreen({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.construction_outlined,
                    size: 64, color: Color(0xFFFFB800)),
                const SizedBox(height: 24),
                const Text(
                  'Under Maintenance',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
                const SizedBox(height: 24),
                Text(
                  'No action is needed. The app will unlock automatically once '
                  'maintenance finishes.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
