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
      for (final c in [_orderChannel, _chatChannel, _systemChannel]) {
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

  static Future<void> subscribe(String topic) async {
    try {
      await FirebaseMessaging.instance.subscribeToTopic(topic);
    } catch (e) {
      debugPrint('PushNotificationService subscribe $topic failed: $e');
    }
  }

  static Future<void> unsubscribe(String topic) async {
    try {
      await FirebaseMessaging.instance.unsubscribeFromTopic(topic);
    } catch (e) {
      debugPrint('PushNotificationService unsubscribe $topic failed: $e');
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
      final title = message.notification?.title ??
          (data['title'] ?? 'SeSe').toString();
      final body = message.notification?.body ??
          (data['body'] ?? 'You have a new update.').toString();
      final channel = _channelFor(data);
      final fullScreen = channel == PushChannels.orders ||
          (data['fullScreen'] ?? '').toString() == 'true';
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
                    : 'System announcements',
            importance: channel == PushChannels.orders
                ? Importance.max
                : Importance.high,
            priority: Priority.high,
            playSound: true,
            sound: const RawResourceAndroidNotificationSound(
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

  /// Heads-up "return to SeSe" alert (bubble tap bridge).
  static Future<void> showReturnToAppAlert({String body = ''}) async {
    try {
      await _local.show(
        id: 9001,
        title: 'Return to SeSe',
        body: body.isEmpty ? 'Tap to open SeSe.' : body,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            PushChannels.orders,
            'Order alerts',
            importance: Importance.high,
            priority: Priority.high,
            playSound: true,
            sound: RawResourceAndroidNotificationSound(
                PushChannels.alertSound),
          ),
          iOS: DarwinNotificationDetails(
              presentAlert: true, presentBadge: true, presentSound: true),
        ),
        payload: 'type=foreground_request',
      );
    } catch (e) {
      debugPrint('PushNotificationService return-to-app failed: $e');
    }
  }
}
