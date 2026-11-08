import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

/// Unified state controller for immersive full-screen map interaction,
/// intelligent bottom sheet minimization (snap-to-edge), and dual restoration
/// triggers (inactivity timer and GPS movement / driving away).
///
/// Abstracted uniformly across Google Maps, Mapbox, and CartoDB mapping engines.
///
/// ### Core Responsibilities:
/// 1. **Interaction Detection:** Captures taps, panning, and gestures across any map engine.
/// 2. **UI Autohide:** Instantly hides non-essential floating UI elements (such as top
///    search bars, floating action cards, or secondary overlays) to give the user an
///    unobstructed, full-screen map view.
/// 3. **Intelligent Sheet Minimization (Snap-to-Edge):** Collapses an open bottom sheet
///    down to its minimum peek/snap extent (e.g. 0.18 or 0.15) leaving a clean drag
///    handle/bar so the user can easily drag it back up. The sheet is NEVER completely
///    dismissed or hidden.
/// 4. **Restoration Trigger A (Inactivity Timer):** If the user stops interacting with the
///    screen for [inactivityDuration] (configurable, default 2 seconds), automatically
///    restores the UI and expands the bottom sheet to standard extent.
/// 5. **Restoration Trigger B (GPS Movement / Driving Away):** When active device/driver
///    location updates indicate significant movement (> [minMovementDistanceMeters] or
///    speed > [minMovementSpeedMps]), immediately restores the UI and re-centers the map,
///    skipping any waiting period.
class MapInteractionController extends ChangeNotifier {
  /// How long to wait after interaction ceases before automatically restoring the UI.
  /// Configurable between 1 and 3 seconds (default 2 seconds).
  final Duration inactivityDuration;

  /// Minimum distance in meters from the interaction origin to qualify as vehicle/user movement.
  final double minMovementDistanceMeters;

  /// Minimum speed in meters per second (~4.3 km/h = 1.2 m/s) to qualify as active driving.
  final double minMovementSpeedMps;

  /// Snap extent to collapse the bottom sheet to during map exploration (e.g. 0.18).
  final double sheetCollapsedExtent;

  /// Standard snap extent to restore the bottom sheet to after exploration (e.g. 0.44).
  final double sheetStandardExtent;

  /// Optional attached [DraggableScrollableController] for direct animated sheet snapping.
  DraggableScrollableController? sheetController;

  /// Optional callback invoked when device movement demands camera re-centering.
  VoidCallback? onRecenter;

  /// Optional callback invoked when the bottom sheet should collapse.
  VoidCallback? onCollapseSheet;

  /// Optional callback invoked when the bottom sheet should restore/expand.
  VoidCallback? onRestoreSheet;

  /// Optional callback invoked when immersive mode changes.
  ValueChanged<bool>? onImmersiveChanged;

  /// Whether full-screen immersive map mode is currently active (floating UI hidden,
  /// sheet minimized down to snap edge).
  bool _isImmersive = false;
  bool get isImmersive => _isImmersive;

  /// Whether the user's hand/pointer is actively touching, dragging, or panning the map canvas.
  bool _isInteracting = false;
  bool get isInteracting => _isInteracting;

  /// Timestamp when the user last touched or dragged the map canvas.
  DateTime? _lastInteractionTime;
  DateTime? get lastInteractionTime => _lastInteractionTime;

  /// Geographic coordinates where the user first initiated manual map exploration.
  double? _originLat;
  double? _originLng;

  Timer? _inactivityTimer;

  MapInteractionController({
    this.inactivityDuration = const Duration(milliseconds: 2000),
    this.minMovementDistanceMeters = 10.0,
    this.minMovementSpeedMps = 1.2,
    this.sheetCollapsedExtent = 0.18,
    this.sheetStandardExtent = 0.44,
    this.sheetController,
    this.onRecenter,
    this.onCollapseSheet,
    this.onRestoreSheet,
    this.onImmersiveChanged,
  });

  /// Attaches a [DraggableScrollableController] to drive bottom sheet animations.
  void attachSheetController(DraggableScrollableController controller) {
    sheetController = controller;
  }

  /// Detaches the current [DraggableScrollableController].
  void detachSheetController() {
    sheetController = null;
  }

  /// Notifies the controller that map canvas interaction has started (tap or drag/pan).
  ///
  /// Instantly transitions into immersive mode: collapses the bottom sheet to its
  /// minimum snap edge, autohides non-essential floating UI elements, and resets the
  /// inactivity timer.
  void notifyInteractionStarted({double? currentLat, double? currentLng}) {
    _isInteracting = true;
    _lastInteractionTime = DateTime.now();

    if (_originLat == null && currentLat != null) {
      _originLat = currentLat;
      _originLng = currentLng;
    }

    _inactivityTimer?.cancel();

    if (!_isImmersive) {
      _isImmersive = true;
      _collapseSheetInternal();
      onImmersiveChanged?.call(true);
      notifyListeners();
    }
  }

  /// Notifies the controller that manual map canvas touch/drag has ended.
  ///
  /// Starts the inactivity countdown timer to restore UI after [inactivityDuration].
  void notifyInteractionEnded() {
    _isInteracting = false;
    _scheduleInactivityTimer();
  }

  /// Schedules the inactivity timer to restore the UI once the user stops interacting.
  void _scheduleInactivityTimer() {
    _inactivityTimer?.cancel();
    _inactivityTimer = Timer(inactivityDuration, () {
      if (!_isInteracting && _isImmersive) {
        restoreUI();
      }
    });
  }

  /// Restores the UI to its normal, non-immersive state:
  /// Smoothly expands the bottom sheet to standard extent and un-hides floating overlays.
  void restoreUI() {
    _inactivityTimer?.cancel();
    _inactivityTimer = null;
    _isInteracting = false;
    _originLat = null;
    _originLng = null;

    if (_isImmersive) {
      _isImmersive = false;
      _restoreSheetInternal();
      onImmersiveChanged?.call(false);
      notifyListeners();
    }
  }

  /// Evaluates GPS location updates for active movement / driving away.
  ///
  /// If the user or vehicle has started moving (exceeds [minMovementSpeedMps] or
  /// moved > [minMovementDistanceMeters] from the interaction origin), immediately
  /// restores the UI and triggers camera re-centering without waiting for the timer.
  void onLocationUpdate(double lat, double lng, {double? speed}) {
    // 1. Check speed-based movement (e.g. driving away > 1.2 m/s ~ 4.3 km/h)
    bool isMoving = speed != null && speed > minMovementSpeedMps;

    // 2. Check distance delta from origin if stationary GPS speed is reported
    if (!isMoving && _originLat != null && _originLng != null) {
      try {
        final dist = Geolocator.distanceBetween(_originLat!, _originLng!, lat, lng);
        if (dist >= minMovementDistanceMeters) {
          isMoving = true;
        }
      } catch (_) {}
    }

    // 3. Immediate restoration on movement: cancel timer, expand sheet, restore overlays & recenter
    if (isMoving && _isImmersive) {
      restoreUI();
      onRecenter?.call();
    }
  }

  /// Smoothly collapses the bottom sheet to [sheetCollapsedExtent].
  void _collapseSheetInternal() {
    final controller = sheetController;
    if (controller != null && controller.isAttached) {
      try {
        controller.animateTo(
          sheetCollapsedExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
        );
      } catch (_) {}
    }
    onCollapseSheet?.call();
  }

  /// Smoothly restores the bottom sheet to [sheetStandardExtent].
  void _restoreSheetInternal() {
    final controller = sheetController;
    if (controller != null && controller.isAttached) {
      try {
        controller.animateTo(
          sheetStandardExtent,
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeOutCubic,
        );
      } catch (_) {}
    }
    onRestoreSheet?.call();
  }

  /// Explicitly collapse the bottom sheet down to [sheetCollapsedExtent].
  void collapseSheet() => _collapseSheetInternal();

  /// Explicitly expand the bottom sheet up to [sheetStandardExtent].
  void expandSheet() => _restoreSheetInternal();

  @override
  void dispose() {
    _inactivityTimer?.cancel();
    super.dispose();
  }
}
