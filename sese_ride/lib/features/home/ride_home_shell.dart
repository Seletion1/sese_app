import 'package:flutter/material.dart';
import 'package:sese_core/sese_core.dart';
import '../customer/presentation/customer_dispatch_screen.dart';
import '../driver/presentation/driver_dashboard_screen.dart';
import '../driver/services/driver_fleet_service.dart';

class RideHomeShell extends StatefulWidget {
  final RegionConfig? config;
  final DriverFleetService? fleetService;

  const RideHomeShell({
    super.key,
    this.config,
    this.fleetService,
  });

  @override
  State<RideHomeShell> createState() => _RideHomeShellState();
}

class _RideHomeShellState extends State<RideHomeShell> {
  int _currentTabIndex = 0;
  late final DriverFleetService _fleetService;

  @override
  void initState() {
    super.initState();
    _fleetService = widget.fleetService ?? DriverFleetService();
  }

  @override
  Widget build(BuildContext context) {
    final screens = [
      CustomerDispatchScreen(initialConfig: widget.config),
      DriverDashboardScreen(
        fleetService: _fleetService,
        config: widget.config,
      ),
    ];

    return Scaffold(
      body: screens[_currentTabIndex],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentTabIndex,
        onDestinationSelected: (idx) => setState(() => _currentTabIndex = idx),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.hail),
            selectedIcon: Icon(Icons.hail),
            label: 'Customer Dispatch',
          ),
          NavigationDestination(
            icon: Icon(Icons.drive_eta),
            selectedIcon: Icon(Icons.drive_eta),
            label: 'Driver Dashboard',
          ),
        ],
      ),
    );
  }
}
