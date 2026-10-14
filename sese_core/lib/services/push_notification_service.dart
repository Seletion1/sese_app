import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Notification channels (Android importance max + custom chime).
class PushChannels {
  PushChannels._();

  /// Order pings: heads-up + full-screen intent capable + custom chime.
  static const orders = 'sese_orders';

  /// Trip/support chat messages.
  static const chat = 'sese_chat';

  /// Verification + system announcements.
  static const system = 'sese_system';

  /// Low-importance ongoing "You are ONLINE" foreground signal.
  ///
  /// Kept separate from [orders] so the sticky notification never competes
  /// with high-priority order heads-ups and never appears as a second
  /// prominent entry in the drawer — Android renders Importance.low channels
  /// below the fold, without a sound or a banner.
  static const driverOnline = 'sese_driver_online';

  /// High-priority admin broadcasts (announcements, safety alerts).
  ///
  /// Importance.max + default sound + vibration so urgent broadcasts break
  /// through Doze and alert instantly. Matches the backend
  /// `sendTargetedBroadcast` payload (`channel_id` + `FLUTTER_NOTIFICATION_CLICK`).
  static const broadcast = 'sese_high_priority_alerts';

  /// Raw resource name (res/raw/sese_alert_chime.wav, no extension).
  static const alertSound = 'sese_alert_chime';
}

/// Background FCM handler: shows a high-priority local notification with
/// the custom chime even when the app is killed. Order pings request the
/// full-screen intent so the popup renders over lock/launcher.
///
/// Must stay a top-level function for `@pragma('vm:entry-point')`.
@pragma('vm:entry-point')
Future<void> pushBackgroundHandler(RemoteMessage message) async {
  try {
    await PushNotificationService.showFromMessage(message);
  } catch (e) {
    debugPrint('pushBackgroundHandler failed: $e');
  }
}

/// Unified high-priority push pipeline (FCM + local notifications).
///
/// - Foreground messages render immediately with sound.
/// - Background/killed messages render via [pushBackgroundHandler].
/// - Taps route through [onTap] with the message data payload.
/// - Topic helpers keep user/driver/staff subscriptions tidy.
///
/// All methods are best-effort and never throw (missing Firebase in tests
/// resolves to no-ops).
class PushNotificationService {
  PushNotificationService._();

  static final FlutterLocalNotificationsPlugin _local =
      FlutterLocalNotificationsPlugin();

  static bool _channelsReady = false;
  static void Function(Map<String, String> data)? _onTap;

  /// Notifier triggered when a silent session termination signal arrives from FCM.
  static final ValueNotifier<Map<String, dynamic>?> driverSessionTerminatedEvents =
      ValueNotifier(null);

  /// Whether local channels were created (false in tests / on failure).
  static bool get channelsReady => _channelsReady;

  static const _orderChannel = AndroidNotificationChannel(
    PushChannels.orders,
    'Order alerts',
    description: 'Incoming order requests with countdown',
    importance: Importance.max,
    playSound: true,
    sound: RawResourceAndroidNotificationSound(PushChannels.alertSound),
    enableVibration: true,
  );
  static const _chatChannel = AndroidNotificationChannel(
    PushChannels.chat,
    'Chat messages',
    description: 'Trip and support chat messages',
    importance: Importance.high,
    playSound: true,
    sound: RawResourceAndroidNotificationSound(PushChannels.alertSound),
  );
  static const _systemChannel = AndroidNotificationChannel(
    PushChannels.system,
    'System announcements',
    description: 'Verification and account announcements',
    importance: Importance.high,
    playSound: true,
    sound: RawResourceAndroidNotificationSound(PushChannels.alertSound),
  );

  /// Low-importance silent channel for the persistent "You are ONLINE" signal.
  ///
  /// [Importance.low] prevents Android from rendering a banner/sound for this
  /// notification; it appears only as a small, non-intrusive entry below the
  /// fold so the driver knows the foreground service is alive. The [orders]
  /// channel (Importance.max) is untouched — order heads-ups still break
  /// through DND as required.
  static const _driverOnlineChannel = AndroidNotificationChannel(
    PushChannels.driverOnline,
    'Driver online status',
    description: 'Persistent signal shown while the driver is receiving trips',
    importance: Importance.low,
    playSound: false,
    enableVibration: false,
  );

  /// Urgent admin broadcasts: heads-up banner + default sound + vibration,
  /// bypassing Doze via the high-priority FCM payload. No full-screen
  /// intent (alerts are urgent, not calls) — tap opens the inbox.
  static const _broadcastChannel = AndroidNotificationChannel(
    PushChannels.broadcast,
    'Announcements',
    description: 'Urgent SeSe announcements and safety alerts',
    importance: Importance.max,
    playSound: true,
    enableVibration: true,
  );

  /// Initializes channels, permissions, foreground rendering, tap routing,
  /// and the background handler. Call once per app start (after Firebase).
  static Future<void> init({
    void Function(Map<String, String> data)? onTap,
  }) async {
    _onTap = onTap;
    try {
      const androidSettings =
          AndroidInitializationSettings('@mipmap/ic_launcher');
      const iosSettings = DarwinInitializationSettings(
        requestAlertPermission: true,
        requestBadgePermission: true,
        requestSoundPermission: true,
      );
      await _local.initialize(
        settings: const InitializationSettings(
            android: androidSettings, iOS: iosSettings),
        onDidReceiveNotificationResponse: (response) {
          _handleTap(response.payload);
        },
      );
      final android = _local.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      for (final c in [
        _orderChannel,
        _chatChannel,
        _systemChannel,
        _driverOnlineChannel,
        _broadcastChannel,
      ]) {
        await android?.createNotificationChannel(c);
      }
      _channelsReady = true;
    } catch (e) {
      debugPrint('PushNotificationService init failed: $e');
      return;
    }

    try {
      final messaging = FirebaseMessaging.instance;
      await messaging.requestPermission(alert: true, badge: true, sound: true);
      await messaging
          .setForegroundNotificationPresentationOptions(
              alert: true, badge: true, sound: true);
      FirebaseMessaging.onMessage.listen((message) {
        showFromMessage(message);
      });
      FirebaseMessaging.onMessageOpenedApp.listen((message) {
        _handleTap(_payloadOf(message));
      });
      FirebaseMessaging.onBackgroundMessage(pushBackgroundHandler);
    } catch (e) {
      debugPrint('PushNotificationService FCM wiring failed: $e');
    }
  }

  /// FCM registration token (send to backend to target this device).
  static Future<String?> token() async {
    try {
      return await FirebaseMessaging.instance.getToken();
    } catch (e) {
      debugPrint('PushNotificationService token failed: $e');
      return null;
    }
  }

  /// UID currently bound to [onTokenRefresh] rewrites (wired once).
  static String? _tokenUid;
  static bool _refreshWired = false;

  /// Registers this device's FCM token for targeted broadcasts.
  ///
  /// Merges `{fcmToken, fcmUpdatedAt, country}` into `users/{uid}` (and
  /// `drivers/{uid}` when [isDriver]) so `sendTargetedBroadcast` can query
  /// matching tokens. Best-effort: never throws. Also wires a one-time
  /// [FirebaseMessaging.onTokenRefresh] listener that rewrites the stored
  /// token for the same uid.
  static Future<void> registerToken({
    required String uid,
    bool isDriver = false,
    String? country,
  }) async {
    if (uid.isEmpty) return;
    try {
      final t = await token();
      if (t == null || t.isEmpty) return;
      await _writeToken(uid: uid, token: t, isDriver: isDriver, country: country);
      _tokenUid = uid;
      if (!_refreshWired) {
        _refreshWired = true;
        FirebaseMessaging.instance.onTokenRefresh.listen((fresh) {
          final bound = _tokenUid;
          if (bound == null || bound.isEmpty) return;
          // ignore: discarded_futures
          _writeToken(uid: bound, token: fresh, isDriver: isDriver);
        });
      }
    } catch (e) {
      debugPrint('PushNotificationService registerToken failed: $e');
    }
  }

  static Future<void> _writeToken({
    required String uid,
    required String token,
    required bool isDriver,
    String? country,
  }) async {
    try {
      final data = <String, dynamic>{
        'fcmToken': token,
        'fcmUpdatedAt': FieldValue.serverTimestamp(),
        if (country != null && country.isNotEmpty) 'country': country,
      };
      final db = FirebaseFirestore.instance;
      await db
          .collection('users')
          .doc(uid)
          .set(data, SetOptions(merge: true));
      if (isDriver) {
        await db
            .collection('drivers')
            .doc(uid)
            .set(data, SetOptions(merge: true));
      }
    } catch (e) {
      debugPrint('PushNotificationService write-token failed: $e');
    }
  }

  /// FCM topics allow only `[a-zA-Z0-9-_.~%]` — anything else (e.g. the
  /// `@` in an email-derived topic like `staff_user@gmail.com`) throws an
  /// assertion. Sanitize centrally so no caller can crash; the mapping is
  /// deterministic, so the backend must publish to the same sanitized name.
  static String sanitizeTopic(String topic) =>
      topic.replaceAll(RegExp(r'[^a-zA-Z0-9\-_.~%]'), '_');

  static Future<void> subscribe(String topic) async {
    final safe = sanitizeTopic(topic);
    try {
      await FirebaseMessaging.instance.subscribeToTopic(safe);
    } catch (e) {
      debugPrint('PushNotificationService subscribe $safe failed: $e');
    }
  }

  static Future<void> unsubscribe(String topic) async {
    final safe = sanitizeTopic(topic);
    try {
      await FirebaseMessaging.instance.unsubscribeFromTopic(safe);
    } catch (e) {
      debugPrint('PushNotificationService unsubscribe $safe failed: $e');
    }
  }

  static String _payloadOf(RemoteMessage message) {
    final data = Map<String, String>.from(message.data.map(
        (k, v) => MapEntry(k.toString(), v.toString())));
    data.putIfAbsent('title', () => message.notification?.title ?? '');
    data.putIfAbsent('body', () => message.notification?.body ?? '');
    return data.entries
        .map((e) =>
            '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}')
        .join('&');
  }

  static Map<String, String> _dataOf(String? payload) {
    final out = <String, String>{};
    if (payload == null || payload.isEmpty) return out;
    for (final part in payload.split('&')) {
      final i = part.indexOf('=');
      if (i < 0) continue;
      out[Uri.decodeComponent(part.substring(0, i))] =
          Uri.decodeComponent(part.substring(i + 1));
    }
    return out;
  }

  static void _handleTap(String? payload) {
    final data = _dataOf(payload);
    if (data.isEmpty) return;
    try {
      _onTap?.call(data);
    } catch (e) {
      debugPrint('PushNotificationService onTap failed: $e');
    }
  }

  static String _channelFor(Map<String, dynamic> data) {
    final type = (data['type'] ?? '').toString();
    if (type == 'broadcast' ||
        (data['channel'] ?? '').toString() == PushChannels.broadcast) {
      return PushChannels.broadcast;
    }
    if (type.startsWith('trip_') ||
        type == 'driver_counter_bid' ||
        type.startsWith('support_') ||
        type.startsWith('chat_') ||
        type == 'trip_chat_message' ||
        type == 'support_reply') {
      return PushChannels.chat;
    }
    if (type.startsWith('order_') ||
        type == 'tier_ping' ||
        type == 'marketplace_broadcast') {
      return PushChannels.orders;
    }
    return PushChannels.system;
  }

  /// Renders a [RemoteMessage] as a high-priority local notification with
  /// the custom chime. Order pings use the full-screen intent.
  static Future<void> showFromMessage(RemoteMessage message) async {
    try {
      final data = Map<String, dynamic>.from(message.data);
      if (data['type'] == 'DRIVER_SESSION_TERMINATED') {
        driverSessionTerminatedEvents.value = data;
        await cancelOnlineAlert();
        return;
      }
      final title = message.notification?.title ??
          (data['title'] ?? 'SeSe').toString();
      final body = message.notification?.body ??
          (data['body'] ?? 'You have a new update.').toString();
      final channel = _channelFor(data);
      final fullScreen = channel == PushChannels.orders ||
          (data['fullScreen'] ?? '').toString() == 'true';
      final isBroadcast = channel == PushChannels.broadcast;
      final id = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      await _local.show(
        id: id,
        title: title,
        body: body,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            channel,
            channel == PushChannels.orders
                ? 'Order alerts'
                : channel == PushChannels.chat
                    ? 'Chat messages'
                    : isBroadcast
                        ? 'Announcements'
                        : 'System announcements',
            importance: channel == PushChannels.orders || isBroadcast
                ? Importance.max
                : Importance.high,
            priority: Priority.high,
            // Broadcasts use the OS default sound per spec; other channels
            // keep the branded SeSe chime.
            playSound: true,
            sound: isBroadcast
                ? null
                : const RawResourceAndroidNotificationSound(
                    PushChannels.alertSound),
            fullScreenIntent: fullScreen,
            category: channel == PushChannels.orders
                ? AndroidNotificationCategory.call
                : AndroidNotificationCategory.message,
            visibility: NotificationVisibility.public,
          ),
          iOS: const DarwinNotificationDetails(
            presentAlert: true,
            presentBadge: true,
            presentSound: true,
          ),
        ),
        payload: _payloadOf(message),
      );
    } catch (e) {
      debugPrint('PushNotificationService showFromMessage failed: $e');
    }
  }


  /// Sticky "SeSe Driver Active" foreground-style notification, shown for the
  /// whole online session and cancelled on go-offline.
  ///
  /// WHY: Android throttles (then kills) background work without a visible
  /// foreground signal. This ongoing notification is that signal — while it
  /// stands, the OS keeps delivering GPS fixes to the live-trip marker and
  /// dispatch heartbeats, so minimizing or task-switching no longer reads
  /// as going offline. Silent (no chime) and non-clearable by swipe.
  ///
  /// SINGLE unified tray item: the `flutter_overlay_window` OverlayService
  /// foreground notification is suppressed via `visibilitySecret`, so this
  /// (id 9002) is the ONLY entry the driver sees while ONLINE. Its
  /// title/body are mirrored as the overlay's `overlayTitle`/`overlayContent`
  /// for the same reason.
  ///
  /// TAP: the content intent is built by `flutter_local_notifications` with
  /// `PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE` and
  /// targets `MainActivity` (singleTop), so tapping restores the app to the
  /// foreground; the `type=foreground_request` payload routes through [init]'s
  /// `onTap` as confirmation.
  static Future<void> showOngoingOnlineAlert() async {
    try {
      await _local.show(
        id: 9002,
        title: 'SeSe Driver Active',
        body: 'You are ONLINE — Receiving trip offers. Tap to open app.',
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            PushChannels.driverOnline,
            'Driver online status',
            importance: Importance.low,
            priority: Priority.low,
            playSound: false,
            ongoing: true,
            autoCancel: false,
          ),
          iOS: DarwinNotificationDetails(
              presentAlert: false, presentBadge: true, presentSound: false),
        ),
        payload: 'type=foreground_request',
      );
    } catch (e) {
      debugPrint('PushNotificationService online-alert failed: $e');
    }
  }

  /// Cancels the sticky online notification (call on go-offline).
  static Future<void> cancelOnlineAlert() async {
    try {
      await _local.cancel(id: 9002);
    } catch (e) {
      debugPrint('PushNotificationService cancel-online-alert failed: $e');
    }
  }
}
