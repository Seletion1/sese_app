import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Selectable high-priority order alert tones, bundled as WAV assets in
/// `sese_core/assets/sounds/`.
enum AlertTone {
  high('sese_alert_high.wav', 'High Alert'),
  pulse('sese_alert_pulse.wav', 'Pulse'),
  chime('sese_alert_chime.wav', 'Chime'),
  siren('sese_alert_siren.wav', 'Siren'),
  digital('sese_alert_digital.wav', 'Digital');

  final String fileName;
  final String displayName;

  const AlertTone(this.fileName, this.displayName);

  /// Package asset path for audioplayers [AssetSource].
  String get asset => 'packages/sese_core/assets/sounds/$fileName';

  /// Fallback path when running sese_core tests directly.
  String get fallback => 'assets/sounds/$fileName';

  static AlertTone fromName(String? name) => AlertTone.values.firstWhere(
        (t) => t.name == name,
        orElse: () => AlertTone.chime,
      );
}

/// Central audio feedback manager for sese_ride and sese_hub.
///
/// Plays short chimes and looping alerts from `sese_core/assets/sounds/`.
/// Alert playback uses a high-priority [AudioContext] (alarm usage on
/// Android, playback category on iOS) so order chimes cut through even
/// when other audio is active. All methods are best-effort — failures are
/// logged but never throw, so audio never blocks UX.
///
/// Usage:
/// ```dart
/// await AppSoundService.instance.playOnlineSound();
/// await AppSoundService.instance.playIncomingOrderAlert();
/// await AppSoundService.instance.stopIncomingOrderAlert();
/// await AppSoundService.instance.previewAlertTone(AlertTone.siren);
/// ```
class AppSoundService {
  AppSoundService._internal();

  static final AppSoundService instance = AppSoundService._internal();

  /// Persisted driver-selected order alert tone.
  static const String alertTonePrefsKey = 'sese_alert_tone';

  /// For tests: inject a mock player factory.
  @visibleForTesting
  AudioPlayer Function()? playerFactory;

  AudioPlayer _createPlayer() {
    if (playerFactory != null) return playerFactory!.call();
    // `prefix: ''` is required, not cosmetic. audioplayers resolves a source as
    // `<AudioCache.prefix><path>` and the default prefix is `'assets/'`, which
    // would look up `assets/packages/sese_core/assets/sounds/...` — a key that
    // does not exist. Asset keys for a package's bundled assets are already
    // fully qualified (`packages/<package>/<path>`), so an empty prefix makes
    // `AssetSource` treat [AlertTone.asset] as a verbatim `rootBundle` key.
    return AudioPlayer()..audioCache = AudioCache(prefix: '');
  }

  /// High-priority context: alarm usage + transient focus on Android,
  /// playback category (ducking others) on iOS.
  static final AudioContext _highPriorityContext = AudioContext(
    android: const AudioContextAndroid(
      isSpeakerphoneOn: false,
      contentType: AndroidContentType.sonification,
      usageType: AndroidUsageType.alarm,
      audioFocus: AndroidAudioFocus.gainTransient,
    ),
    iOS: AudioContextIOS(
      category: AVAudioSessionCategory.playback,
      options: const {AVAudioSessionOptions.duckOthers},
    ),
  );

  Future<void> _applyAlertContext(AudioPlayer player) async {
    try {
      await player.setAudioContext(_highPriorityContext);
    } catch (e) {
      debugPrint('AppSoundService setAudioContext failed: $e');
    }
  }

  AudioPlayer? _shortPlayer;
  AudioPlayer? _orderPlayer;
  AudioPlayer? _sirenPlayer;
  Timer? _minDurationTimer;
  DateTime? _orderStart;
  Duration _orderMinDuration = const Duration(seconds: 6);
  bool _orderWantsStop = false;

  AlertTone _selectedTone = AlertTone.chime;
  bool _toneLoaded = false;

  // --- Asset paths ---
  // Package asset path for audioplayers AssetSource.
  // When assets live in sese_core, consuming apps reference via
  // `packages/sese_core/...`.
  static const String _onlineChime =
      'packages/sese_core/assets/sounds/online_chime.wav';
  static const String _offlineChime =
      'packages/sese_core/assets/sounds/offline_chime.wav';
  static const String _incomingMessage =
      'packages/sese_core/assets/sounds/incoming_message.wav';
  static const String _incomingOrderAlert =
      'packages/sese_core/assets/sounds/incoming_order_alert.wav';

  // Fallback paths if package prefix fails (e.g., when running sese_core
  // tests directly).
  static const String _onlineChimeFallback = 'assets/sounds/online_chime.wav';
  static const String _offlineChimeFallback =
      'assets/sounds/offline_chime.wav';
  static const String _incomingMessageFallback =
      'assets/sounds/incoming_message.wav';
  static const String _incomingOrderAlertFallback =
      'assets/sounds/incoming_order_alert.wav';

  /// Currently selected order alert tone (defaults to chime until prefs
  /// load). Call [loadSelectedTone] at startup to restore the saved choice.
  AlertTone get selectedTone => _selectedTone;

  /// Restores the driver's saved alert tone from [SharedPreferences].
  Future<AlertTone> loadSelectedTone() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _selectedTone =
          AlertTone.fromName(prefs.getString(alertTonePrefsKey));
    } catch (e) {
      debugPrint('AppSoundService loadSelectedTone failed: $e');
    }
    _toneLoaded = true;
    return _selectedTone;
  }

  /// Persists the driver's alert tone choice. Takes effect on the next
  /// [playIncomingOrderAlert] call.
  Future<void> setSelectedTone(AlertTone tone) async {
    _selectedTone = tone;
    _toneLoaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(alertTonePrefsKey, tone.name);
    } catch (e) {
      debugPrint('AppSoundService setSelectedTone failed: $e');
    }
  }

  Future<void> _playOnce(String asset, String fallback) async {
    try {
      _shortPlayer ??= _createPlayer();
      // One-shots get the same high-priority context as the loops (alarm
      // usage on Android, playback category on iOS) so a toggle chime or
      // tone preview is never ducked by other audio. Matches the class doc.
      await _applyAlertContext(_shortPlayer!);
      // Ensure one-shot mode.
      await _shortPlayer!.setReleaseMode(ReleaseMode.stop);
      try {
        await _shortPlayer!.play(AssetSource(asset));
      } catch (_) {
        // Fallback to non-package path.
        await _shortPlayer!.play(AssetSource(fallback));
      }
    } catch (e) {
      debugPrint('AppSoundService _playOnce $asset failed: $e');
    }
  }

  /// Short toggle chime (~0.5s) played when driver goes online.
  Future<void> playOnlineSound() async {
    await _playOnce(_onlineChime, _onlineChimeFallback);
  }

  /// Short double-tone (~0.5s) played when driver goes offline.
  Future<void> playOfflineSound() async {
    await _playOnce(_offlineChime, _offlineChimeFallback);
  }

  /// Short notification chime (~1.0s) for incoming chat/support messages.
  Future<void> playIncomingMessageSound() async {
    await _playOnce(_incomingMessage, _incomingMessageFallback);
  }

  /// One-shot preview of an alert tone (used by the sound selector in
  /// driver profile settings).
  Future<void> previewAlertTone(AlertTone tone) async {
    await _playOnce(tone.asset, tone.fallback);
  }

  /// High-pitch urgent siren loop for payment-confirmation protection
  /// (e.g. blocked auto-start on cash/split orders). Runs until
  /// [stopSirenAlert] is called.
  Future<void> playSirenAlert() async {
    try {
      _sirenPlayer ??= _createPlayer();
      await _applyAlertContext(_sirenPlayer!);
      await _sirenPlayer!.setReleaseMode(ReleaseMode.loop);
      try {
        await _sirenPlayer!.play(AssetSource(AlertTone.siren.asset));
      } catch (_) {
        await _sirenPlayer!.play(AssetSource(AlertTone.siren.fallback));
      }
    } catch (e) {
      debugPrint('AppSoundService playSirenAlert failed: $e');
    }
  }

  /// Stops the siren protection loop.
  Future<void> stopSirenAlert() async {
    try {
      await _sirenPlayer?.stop();
      await _sirenPlayer?.setReleaseMode(ReleaseMode.stop);
    } catch (e) {
      debugPrint('AppSoundService stopSirenAlert failed: $e');
    }
  }

  /// Urgent order-offer alarm loop in the driver's selected [AlertTone].
  ///
  /// - Applies the high-priority [AudioContext] and sets [ReleaseMode.loop],
  ///   starting playback immediately.
  /// - Enforces a minimum playback duration of [minDuration] (default 6s —
  ///   the full offer countdown). If [stopIncomingOrderAlert] is called
  ///   before the minimum elapses, stopping is deferred until it is reached.
  /// - The loop otherwise continues until [stopIncomingOrderAlert] is called
  ///   (e.g., when the sheet/timer remains active).
  /// - Re-entrant: if the loop is already playing (dashboard + sheet both
  ///   fire on the same offer), the 6s clock restarts but the player is not
  ///   torn down and recreated — no audible glitch, no stacked loops.
  Future<void> playIncomingOrderAlert(
      {Duration minDuration = const Duration(seconds: 6)}) async {
    try {
      if (!_toneLoaded) await loadSelectedTone();
      _orderWantsStop = false;
      _minDurationTimer?.cancel();
      _orderMinDuration = minDuration;
      _orderStart = DateTime.now();

      _orderPlayer ??= _createPlayer();
      await _applyAlertContext(_orderPlayer!);
      await _orderPlayer!.setReleaseMode(ReleaseMode.loop);
      if (_orderPlayer!.state != PlayerState.playing) {
        // Not already looping: start the tone. When the dashboard fired and
        // then the sheet fires for the same offer, the player is already
        // playing — restarting `play` would audibly cut and restart the tone,
        // so skip straight to the clock reset below.
        try {
          await _orderPlayer!.play(AssetSource(_selectedTone.asset));
        } catch (_) {
          // Fall back to the legacy packaged mp3 alert.
          try {
            await _orderPlayer!.play(AssetSource(_incomingOrderAlert));
          } catch (_) {
            await _orderPlayer!.play(AssetSource(_incomingOrderAlertFallback));
          }
        }
      }

      // Ensure at least minDuration of audible alert even if stop is called
      // immediately (e.g., rapid accept). The timer only sets a flag; actual
      // stop logic checks elapsed time.
      _minDurationTimer?.cancel();
      _minDurationTimer = Timer(minDuration, () {
        if (_orderWantsStop) {
          _doStopOrderAlert();
        }
      });
    } catch (e) {
      debugPrint('AppSoundService playIncomingOrderAlert failed: $e');
    }
  }

  /// Stops the looping order alert immediately, or after the minimum duration
  /// if called too early.
  Future<void> stopIncomingOrderAlert() async {
    if (_orderPlayer == null) return;
    final start = _orderStart;
    if (start != null) {
      final elapsed = DateTime.now().difference(start);
      final remaining = _orderMinDuration - elapsed;
      if (remaining > Duration.zero) {
        // Defer stop until minimum duration fulfilled.
        _orderWantsStop = true;
        _minDurationTimer?.cancel();
        _minDurationTimer = Timer(remaining, () {
          _doStopOrderAlert();
        });
        return;
      }
    }
    await _doStopOrderAlert();
  }

  Future<void> _doStopOrderAlert() async {
    try {
      _minDurationTimer?.cancel();
      _minDurationTimer = null;
      _orderWantsStop = false;
      _orderStart = null;
      await _orderPlayer?.stop();
      await _orderPlayer?.setReleaseMode(ReleaseMode.stop);
    } catch (e) {
      debugPrint('AppSoundService stopIncomingOrderAlert failed: $e');
    }
  }

  /// For tests: reset internal state.
  @visibleForTesting
  Future<void> dispose() async {
    _minDurationTimer?.cancel();
    _minDurationTimer = null;
    _orderWantsStop = false;
    _orderStart = null;
    _toneLoaded = false;
    try {
      await _shortPlayer?.dispose();
    } catch (_) {}
    try {
      await _orderPlayer?.dispose();
    } catch (_) {}
    try {
      await _sirenPlayer?.dispose();
    } catch (_) {}
    _shortPlayer = null;
    _orderPlayer = null;
    _sirenPlayer = null;
  }
}
