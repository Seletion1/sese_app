import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

export 'package:flutter_local_notifications/flutter_local_notifications.dart'
    show NotificationResponse, NotificationResponseType;

/// Notification channels (Android importance max + custom chime).
class PushChannels {
  PushChannels._();

  /// Order pings: heads-up + full-screen intent capable + custom chime.
  static const orders = 'sese_orders';

  /// Play-Store-compliant heads-up driver offer banners with Accept/Decline actions.
  static const driverOffers = 'sese_driver_offers';

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

  /// In-app VoIP audio calls: heads-up alert with caller name, Accept & Decline actions.
  static const calls = 'sese_calls';

  /// Raw resource name (res/raw/sese_alert_chime.wav, no extension).
  static const alertSound = 'sese_alert_chime';
}

/// Default background FCM handler used by [PushNotificationService.init] when
/// the caller does not supply a custom [backgroundMessageHandler].
///
/// Renders a high-priority local notification for every message type.
/// Driver apps (sese_ride) supply their own handler via
/// [PushNotificationService.init] that fires the full-screen overlay order
/// card directly for order pings — this default is the notification-only
/// fallback for non-driver contexts (sese_hub) and unit tests.
///
/// **Payload persistence for cold-start**
/// For offer-type messages the payload is written to SharedPreferences so the
/// foreground isolate can consume it on the next launch via
/// [PushNotificationService.consumePendingOfferPayload].
///
/// Must stay a top-level function for `@pragma('vm:entry-point')`.
@pragma('vm:entry-point')
Future<void> pushBackgroundHandler(RemoteMessage message) async {
  // Persist offer payloads for cold-start handoff regardless of path.
  final type = (message.data['type'] ?? '').toString();
  const offerTypes = {
    'trip_offer',
    'direct_ping',
    'tier_ping',
    'marketplace_broadcast',
  };
  if (offerTypes.contains(type)) {
    try {
      final prefs = await SharedPreferences.getInstance();
      final entries = message.data.entries
          .map((e) =>
              '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value.toString())}')
          .join('&');
      await prefs.setString('pending_offer_payload', entries);
      debugPrint(
          'pushBackgroundHandler: persisted offer payload (trip: ${message.data['tripId']})');
    } catch (e) {
      debugPrint(
          'pushBackgroundHandler: payload persist failed (non-fatal): $e');
    }
  }

  // Show a standard high-priority notification (non-driver contexts / fallback).
  try {
    await PushNotificationService.showFromMessage(message);
  } catch (e) {
    debugPrint('pushBackgroundHandler: showFromMessage failed: $e');
  }
}

/// Typedef matching [FirebaseMessaging.onBackgroundMessage]'s handler signature
/// so callers can inject a custom background handler via
/// [PushNotificationService.init].
typedef BackgroundMessageHandler = Future<void> Function(RemoteMessage message);

/// Unified high-priority push pipeline (FCM + local notifications).
///
/// - Foreground messages render immediately with sound.
/// - Background/killed messages render via the handler supplied to [init]
///   (defaults to [pushBackgroundHandler] — notification-only).
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

  /// Latest incoming order offer event payload received via FCM / fullScreenIntent / notification tap.
  static final ValueNotifier<Map<String, String>?> incomingOfferNotifier =
      ValueNotifier(null);

  /// Whether the app is currently in the foreground (resumed).
  ///
  /// When true, incoming driver offer heads-up banners are suppressed because
  /// the active dashboard renders the offer directly via [onMessageDataStream].
  static bool isAppInForeground = false;

  /// Whether local channels were created (false in tests / on failure).
  static bool get channelsReady => _channelsReady;

  static const _driverOffersChannel = AndroidNotificationChannel(
    PushChannels.driverOffers,
    'Driver order offers',
    description: 'High-priority incoming ride and delivery offers',
    importance: Importance.max,
    playSound: true,
    sound: RawResourceAndroidNotificationSound(PushChannels.alertSound),
    enableVibration: true,
  );
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

  /// High-priority heads-up channel for incoming VoIP calls with action buttons.
  static const _callChannel = AndroidNotificationChannel(
    PushChannels.calls,
    'Incoming calls',
    description: 'High-priority heads-up alerts for incoming voice calls',
    importance: Importance.max,
    playSound: true,
    sound: RawResourceAndroidNotificationSound(PushChannels.alertSound),
    enableVibration: true,
  );

  /// Stream broadcasting data payloads received via foreground FCM messages.
  static final StreamController<Map<String, String>> onMessageDataStream =
      StreamController<Map<String, String>>.broadcast();

  /// Initializes channels, permissions, foreground rendering, tap routing,
  /// and the background handler. Call once per app start (after Firebase).
  ///
  /// [onTap] is invoked with the FCM data map when the user taps a local
  /// notification or a background message notification.
  ///
  /// [backgroundMessageHandler] overrides the default [pushBackgroundHandler].
  /// Supply a custom top-level `@pragma('vm:entry-point')` function here when
  /// the app needs richer background behaviour — for example, `sese_ride`
  /// passes its overlay-capable handler so order pings fire the full-screen
  /// order card directly instead of a banner notification.
  ///
  /// Set [requestPermissionImmediately] to true ONLY when immediate cold-start
  /// system prompt is desired. For role-based onboarding dashboards (e.g. `sese_ride`),
  /// leave false (the default) so no permissions are requested until after role selection.
  static Future<void> init({
    void Function(Map<String, String> data)? onTap,
    BackgroundMessageHandler? backgroundMessageHandler,
    DidReceiveBackgroundNotificationResponseCallback?
        onBackgroundNotificationResponse,
    bool requestPermissionImmediately = false,
  }) async {
    _onTap = onTap;
    try {
      const androidSettings =
          AndroidInitializationSettings('@mipmap/ic_launcher');
      final iosSettings = DarwinInitializationSettings(
        requestAlertPermission: requestPermissionImmediately,
        requestBadgePermission: requestPermissionImmediately,
        requestSoundPermission: requestPermissionImmediately,
        notificationCategories: <DarwinNotificationCategory>[
          DarwinNotificationCategory(
            PushChannels.driverOffers,
            actions: <DarwinNotificationAction>[
              DarwinNotificationAction.plain(
                'accept_offer',
                'Accept',
                options: <DarwinNotificationActionOption>{
                  DarwinNotificationActionOption.foreground,
                },
              ),
              DarwinNotificationAction.plain(
                'decline_offer',
                'Decline',
                options: <DarwinNotificationActionOption>{
                  DarwinNotificationActionOption.destructive,
                },
              ),
            ],
          ),
        ],
      );
      await _local.initialize(
        settings: InitializationSettings(
            android: androidSettings, iOS: iosSettings),
        onDidReceiveNotificationResponse: (response) {
          _handleTap(response.payload, actionId: response.actionId);
        },
        onDidReceiveBackgroundNotificationResponse:
            onBackgroundNotificationResponse,
      );
      final android = _local.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      for (final c in [
        _driverOffersChannel,
        _orderChannel,
        _chatChannel,
        _systemChannel,
        _driverOnlineChannel,
        _broadcastChannel,
        _callChannel,
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
      if (requestPermissionImmediately) {
        await messaging.requestPermission(alert: true, badge: true, sound: true);
      }
      await messaging
          .setForegroundNotificationPresentationOptions(
              alert: true, badge: true, sound: true);
      FirebaseMessaging.onMessage.listen((message) {
        showFromMessage(message);
        try {
          final data = Map<String, String>.from(message.data.map(
              (k, v) => MapEntry(k.toString(), v.toString())));
          onMessageDataStream.add(data);
        } catch (_) {}
      });
      FirebaseMessaging.onMessageOpenedApp.listen((message) {
        _handleTap(_payloadOf(message));
      });
      FirebaseMessaging.onBackgroundMessage(
          backgroundMessageHandler ?? pushBackgroundHandler);

      // Check if launched from a terminated/killed state notification tap
      final initialMessage = await messaging.getInitialMessage();
      if (initialMessage != null) {
        _handleTap(_payloadOf(initialMessage));
      }
      final launchDetails = await _local.getNotificationAppLaunchDetails();
      if (launchDetails?.didNotificationLaunchApp == true &&
          launchDetails?.notificationResponse?.payload != null) {
        _handleTap(launchDetails!.notificationResponse!.payload);
      }
    } catch (e) {
      debugPrint('PushNotificationService FCM wiring failed: $e');
    }
  }

  /// Explicitly requests notification permissions on-demand (e.g., from the
  /// unified role-based Permission Dashboard after user selects role).
  static Future<NotificationSettings?> requestNotificationPermission() async {
    try {
      final messaging = FirebaseMessaging.instance;
      return await messaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );
    } catch (e) {
      debugPrint('PushNotificationService requestNotificationPermission error: $e');
      return null;
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

  static void _handleTap(String? payload, {String? actionId}) {
    final data = _dataOf(payload);
    if (data.isEmpty) return;
    if (actionId != null && actionId.isNotEmpty) {
      data['actionId'] = actionId;
    }
    try {
      _onTap?.call(data);
    } catch (e) {
      debugPrint('PushNotificationService onTap failed: $e');
    }
    final type = data['type'] ?? '';
    const offerTypes = {
      'new_trip_offer',
      'trip_offer',
      'direct_ping',
      'tier_ping',
      'marketplace_broadcast',
    };
    if (offerTypes.contains(type) &&
        actionId != 'decline' &&
        actionId != 'decline_order' &&
        actionId != 'decline_offer') {
      incomingOfferNotifier.value = data;
    }
    try {
      onMessageDataStream.add(data);
    } catch (_) {}
  }

  static String _channelFor(Map<String, dynamic> data) {
    final type = (data['type'] ?? '').toString();
    if (type == 'incoming_call' || type == 'call' || type == 'voip_call') {
      return PushChannels.calls;
    }
    if (type == 'broadcast' ||
        (data['channel'] ?? '').toString() == PushChannels.broadcast) {
      return PushChannels.broadcast;
    }
    // Order offer & dispatch pings MUST be evaluated BEFORE generic 'trip_' prefix
    // check so that 'trip_offer' is not trapped in the chat channel!
    if (type == 'new_trip_offer' ||
        type == 'trip_offer' ||
        type == 'direct_ping' ||
        type == 'tier_ping' ||
        type == 'marketplace_broadcast') {
      return PushChannels.driverOffers;
    }
    if (type.startsWith('order') ||
        type == 'dropoff_approval_request' ||
        type == 'drop_off_confirmation' ||
        type == 'dropoff_approval' ||
        type == 'dropoff_approval_response') {
      return PushChannels.orders;
    }
    if (type.startsWith('trip_') ||
        type == 'driver_counter_bid' ||
        type.startsWith('support_') ||
        type.startsWith('chat_') ||
        type == 'trip_chat_message' ||
        type == 'support_reply') {
      return PushChannels.chat;
    }
    return PushChannels.system;
  }

  /// Renders a [RemoteMessage] as a high-priority heads-up notification with
  /// action buttons (Open/Accept & Decline) compliant with targetSdk 36 and Google Play policies.
  ///
  /// USE_FULL_SCREEN_INTENT is stripped to comply with Google Play Console declarations.
  /// Heads-up notifications with action buttons (showsUserInterface: true) reliably bring
  /// the app to the foreground on user interaction without background activity launch blocks.
  /// Formats a driver offer notification banner and computes its remaining
  /// [timeoutAfterMs] window.
  ///
  /// Returns `null` when `expiresAtMs` is present and already expired relative
  /// to [now]. Uses a deterministic positive 31-bit notification ID derived
  /// from `tripId` so duplicate topic deliveries update instead of stacking.
  static ({int id, String title, String body, int? timeoutAfterMs})?
      buildDriverOfferBanner(
    Map<String, dynamic> data, {
    DateTime? now,
    String? fallbackTitle,
    String? fallbackBody,
  }) {
    final current = now ?? DateTime.now();
    final expiresRaw = (data['expiresAtMs'] ?? '').toString().trim();
    int? timeoutAfterMs;
    if (expiresRaw.isNotEmpty) {
      final expiresAtMs = int.tryParse(expiresRaw);
      if (expiresAtMs != null) {
        final remaining = expiresAtMs - current.millisecondsSinceEpoch;
        if (remaining <= 0) {
          return null;
        }
        timeoutAfterMs = remaining;
      }
    }

    final tripId = (data['tripId'] ?? '').toString().trim();
    final fare = (data['fare'] ?? '').toString().trim();
    final rawCurrency = (data['currency'] ?? '').toString().trim();
    final currency =
        (rawCurrency.isEmpty || rawCurrency == 'NGN') ? '₦' : rawCurrency;
    final pickup = (data['pickupAddress'] ?? data['pickup'] ?? '').toString().trim();
    final dropoff = (data['dropoffAddress'] ?? data['dropoff'] ?? '').toString().trim();

    final title = fare.isNotEmpty
        ? 'New Order • $currency$fare'
        : ((data['offerTitle'] ?? data['title'] ?? fallbackTitle ?? 'New Order')
            .toString());

    final body = (pickup.isNotEmpty || dropoff.isNotEmpty)
        ? 'Pickup: ${pickup.isNotEmpty ? pickup : "See map"}\n'
            'Drop-off: ${dropoff.isNotEmpty ? dropoff : "See map"}'
        : ((data['offerBody'] ??
                data['body'] ??
                fallbackBody ??
                'Tap to view order details.')
            .toString());

    final id = tripId.isNotEmpty
        ? (tripId.hashCode & 0x7fffffff)
        : (current.millisecondsSinceEpoch ~/ 1000);

    return (
      id: id,
      title: title,
      body: body,
      timeoutAfterMs: timeoutAfterMs,
    );
  }

  static Future<void> _ensureChannelsForBackground() async {
    if (_channelsReady) return;
    try {
      const androidSettings =
          AndroidInitializationSettings('@mipmap/ic_launcher');
      await _local.initialize(
        settings: const InitializationSettings(android: androidSettings),
      );
      final android = _local.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      for (final c in [
        _driverOffersChannel,
        _orderChannel,
        _chatChannel,
        _systemChannel,
        _driverOnlineChannel,
        _broadcastChannel,
        _callChannel,
      ]) {
        await android?.createNotificationChannel(c);
      }
      _channelsReady = true;
    } catch (e) {
      debugPrint('PushNotificationService background init error: $e');
    }
  }

  static Future<void> showFromMessage(RemoteMessage message) async {
    try {
      await _ensureChannelsForBackground();
      final data = Map<String, dynamic>.from(message.data);
      if (data['type'] == 'DRIVER_SESSION_TERMINATED') {
        driverSessionTerminatedEvents.value = data;
        await cancelOnlineAlert();
        return;
      }
      final channel = _channelFor(data);
      final isCall = channel == PushChannels.calls;
      final isOffer = channel == PushChannels.driverOffers;
      final isOrder = channel == PushChannels.orders;
      final isBroadcast = channel == PushChannels.broadcast;

      if (isOffer && isAppInForeground) {
        return;
      }

      late final String title;
      late final String body;
      late final int id;
      int? timeoutAfterMs;

      if (isOffer) {
        final banner = buildDriverOfferBanner(
          data,
          fallbackTitle: message.notification?.title,
          fallbackBody: message.notification?.body,
        );
        if (banner == null) {
          return;
        }
        title = banner.title;
        body = banner.body;
        id = banner.id;
        timeoutAfterMs = banner.timeoutAfterMs;
      } else {
        title = message.notification?.title ??
            (data['title'] ?? 'SeSe').toString();
        body = message.notification?.body ??
            (data['body'] ?? 'You have a new update.').toString();
        id = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      }

      final List<AndroidNotificationAction>? actions;
      if (isCall) {
        actions = const <AndroidNotificationAction>[
          AndroidNotificationAction(
            'accept_call',
            'Accept',
            showsUserInterface: true,
          ),
          AndroidNotificationAction(
            'decline_call',
            'Decline',
            cancelNotification: true,
          ),
        ];
      } else if (isOffer) {
        actions = const <AndroidNotificationAction>[
          AndroidNotificationAction(
            'accept_offer',
            'Accept',
            showsUserInterface: true,
            cancelNotification: true,
          ),
          AndroidNotificationAction(
            'decline_offer',
            'Decline',
            showsUserInterface: false,
            cancelNotification: true,
          ),
        ];
      } else if (isOrder) {
        actions = const <AndroidNotificationAction>[
          AndroidNotificationAction(
            'open_order',
            'Open Order',
            showsUserInterface: true,
          ),
          AndroidNotificationAction(
            'decline_order',
            'Decline',
            cancelNotification: true,
          ),
        ];
      } else {
        actions = null;
      }

      await _local.show(
        id: id,
        title: title,
        body: body,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            channel,
            isCall
                ? 'Incoming calls'
                : isOffer
                    ? 'Driver order offers'
                    : isOrder
                        ? 'Order alerts'
                        : channel == PushChannels.chat
                            ? 'Chat messages'
                            : isBroadcast
                                ? 'Announcements'
                                : 'System announcements',
            importance: (isCall || isOffer || isOrder || isBroadcast)
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
            fullScreenIntent: false,
            styleInformation: isOffer
                ? BigTextStyleInformation(body, contentTitle: title)
                : null,
            timeoutAfter: isOffer ? timeoutAfterMs : null,
            category: (isCall || isOffer || isOrder)
                ? AndroidNotificationCategory.call
                : AndroidNotificationCategory.message,
            visibility: NotificationVisibility.public,
            enableVibration: true,
            vibrationPattern: (isCall || isOffer || isOrder)
                ? Int64List.fromList([0, 1000, 500, 1000, 500, 1000])
                : null,
            audioAttributesUsage: (isCall || isOffer || isOrder)
                ? AudioAttributesUsage.notificationRingtone
                : AudioAttributesUsage.notification,
            actions: actions,
          ),
          iOS: DarwinNotificationDetails(
            presentAlert: true,
            presentBadge: true,
            presentSound: true,
            interruptionLevel: InterruptionLevel.timeSensitive,
            categoryIdentifier: isOffer ? PushChannels.driverOffers : null,
          ),
        ),
        payload: _payloadOf(message),
      );
    } catch (e) {
      debugPrint('PushNotificationService showFromMessage failed: $e');
    }
  }

  static const int _incomingCallNotificationId = 888001;

  /// Displays a high-priority heads-up notification for an incoming in-app voice call
  /// with caller name and Accept / Decline action buttons.
  ///
  /// Fully compliant with targetSdk 36 and Google Play Console policies without
  /// requesting `USE_FULL_SCREEN_INTENT`.
  static Future<void> showIncomingCallNotification({
    required String callId,
    required String callerId,
    required String callerName,
    String? callerAvatar,
  }) async {
    try {
      final payloadData = {
        'type': 'incoming_call',
        'callId': callId,
        'callerId': callerId,
        'callerName': callerName,
        if (callerAvatar != null && callerAvatar.isNotEmpty)
          'callerAvatar': callerAvatar,
      };
      final payload = payloadData.entries
          .map((e) =>
              '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}')
          .join('&');

      await _local.show(
        id: _incomingCallNotificationId,
        title: callerName.isNotEmpty ? callerName : 'Incoming Call',
        body: 'Incoming audio call...',
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            PushChannels.calls,
            'Incoming calls',
            channelDescription:
                'High-priority heads-up alerts for incoming voice calls',
            importance: Importance.max,
            priority: Priority.high,
            playSound: true,
            sound: RawResourceAndroidNotificationSound(PushChannels.alertSound),
            fullScreenIntent: false,
            category: AndroidNotificationCategory.call,
            visibility: NotificationVisibility.public,
            enableVibration: true,
            audioAttributesUsage: AudioAttributesUsage.notificationRingtone,
            actions: <AndroidNotificationAction>[
              AndroidNotificationAction(
                'accept_call',
                'Accept',
                showsUserInterface: true,
              ),
              AndroidNotificationAction(
                'decline_call',
                'Decline',
                cancelNotification: true,
              ),
            ],
          ),
          iOS: DarwinNotificationDetails(
            presentAlert: true,
            presentBadge: true,
            presentSound: true,
            interruptionLevel: InterruptionLevel.timeSensitive,
          ),
        ),
        payload: payload,
      );
    } catch (e) {
      debugPrint('PushNotificationService showIncomingCallNotification failed: $e');
    }
  }

  /// Cancels any active incoming-call heads-up notification.
  static Future<void> cancelIncomingCallNotification() async {
    try {
      await _local.cancel(id: _incomingCallNotificationId);
    } catch (e) {
      debugPrint('PushNotificationService cancelIncomingCallNotification failed: $e');
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
  /// SINGLE unified tray item: this ongoing notification (id 9002) is the primary
  /// entry the driver sees while ONLINE. Tapping it restores the app to the foreground.
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

  // ── Cold-start offer handoff ──────────────────────────────────────────────

  /// SharedPreferences key where [pushBackgroundHandler] persists the offer
  /// FCM payload for the foreground isolate to consume on cold-start.
  static const _pendingOfferKey = 'pending_offer_payload';

  /// Reads and clears any driver offer payload that was stashed by
  /// [pushBackgroundHandler] while the app was killed.
  ///
  /// Returns the decoded data map when a pending offer exists, or `null`
  /// when there is nothing to consume. The entry is atomically deleted after
  /// reading so it is never replayed on a subsequent launch.
  ///
  /// Call this once during app startup (after Firebase + notifications init)
  /// to surface killed-state offers without a Firestore round-trip.
  static Future<Map<String, String>?> consumePendingOfferPayload() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_pendingOfferKey);
      if (raw == null || raw.isEmpty) return null;
      await prefs.remove(_pendingOfferKey);
      return _dataOf(raw);
    } catch (e) {
      debugPrint('PushNotificationService.consumePendingOfferPayload failed: $e');
      return null;
    }
  }
}
