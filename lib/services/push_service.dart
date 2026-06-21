import 'dart:convert';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:logger/logger.dart';

/// FCM background handler. Must be a top-level (or static) function so it can run
/// in its own isolate when the app is backgrounded or terminated.
@pragma('vm:entry-point')
Future<void> firebaseBackgroundHandler(RemoteMessage message) async {
  try {
    await Firebase.initializeApp();
  } catch (_) {}
  await PushService.showIncomingCallFromData(message.data);
}

/// Push notifications for incoming calls while the app is closed.
///
/// Flow: PortaSIP sends an FCM push (RFC 8599) → this wakes the app → we show a
/// full-screen "Incoming call" notification. Accept brings the app forward and
/// the SIP layer answers the INVITE; Decline dismisses it.
///
/// Push only works once a real Firebase project's google-services.json is in
/// place AND Backspace/PortaSIP is configured to push to it (see SETUP_PUSH.md).
/// Without those, [available] stays false and the app behaves exactly as before.
class PushService {
  static final _log = Logger(printer: PrettyPrinter(methodCount: 0));
  static final _local = FlutterLocalNotificationsPlugin();

  static const _callChannelId = 'cosmiq_incoming_calls';
  static const _callNotificationId = 1001;

  static bool _available = false;
  static String? _fcmToken;
  static String? _senderId;

  /// Whether Firebase initialised (real config present) — gates push registration.
  static bool get available => _available;

  /// The device FCM token — used as the SIP `pn-prm` push parameter.
  static String? get fcmToken => _fcmToken;

  /// The FCM sender id (Firebase project number) — used as the `pn-param`.
  static String? get senderId => _senderId;

  /// Wired up by the app to react to the call notification's actions.
  static void Function(Map<String, dynamic> call)? onAcceptCall;
  static void Function(Map<String, dynamic> call)? onDeclineCall;

  static Future<void> init() async {
    // Entirely guarded: with no/placeholder Firebase config the token fetch
    // fails — push stays disabled and the app runs exactly as before.
    try {
      await Firebase.initializeApp();
      await _initLocalNotifications();

      final messaging = FirebaseMessaging.instance;
      await messaging.requestPermission(alert: true, badge: true, sound: true);
      FirebaseMessaging.onBackgroundMessage(firebaseBackgroundHandler);

      _senderId = Firebase.app().options.messagingSenderId;
      _fcmToken = await messaging.getToken();
      _available = _fcmToken != null && _fcmToken!.isNotEmpty;
      _log.i('Push ${_available ? "enabled" : "unavailable (no token)"}');
      messaging.onTokenRefresh.listen((t) => _fcmToken = t);

      // Foreground push, or app opened from a (non-call) push.
      FirebaseMessaging.onMessage.listen((m) => _handleData(m.data));
      FirebaseMessaging.onMessageOpenedApp.listen((m) => _handleData(m.data));
    } catch (e) {
      _log.w('Push disabled (Firebase not configured): $e');
      _available = false;
    }
  }

  static Future<void> _initLocalNotifications() async {
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    await _local.initialize(
      const InitializationSettings(android: android),
      onDidReceiveNotificationResponse: _onNotificationAction,
    );
    final androidImpl = _local.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await androidImpl?.createNotificationChannel(const AndroidNotificationChannel(
      _callChannelId,
      'Incoming Calls',
      description: 'Full-screen notifications for incoming VoIP calls',
      importance: Importance.max,
      playSound: true,
    ));
    await androidImpl?.requestNotificationsPermission();
  }

  static void _handleData(Map<String, dynamic> data) {
    if (data['type'] == 'incoming_call' || data.containsKey('caller')) {
      showIncomingCall(data);
    }
  }

  /// Entry point usable from the background isolate (ensures the plugin is set up).
  static Future<void> showIncomingCallFromData(Map<String, dynamic> data) async {
    await _initLocalNotifications();
    await showIncomingCall(data);
  }

  static Future<void> showIncomingCall(Map<String, dynamic> data) async {
    final caller = (data['caller'] ?? data['from'] ?? 'Unknown').toString();
    final details = AndroidNotificationDetails(
      _callChannelId,
      'Incoming Calls',
      importance: Importance.max,
      priority: Priority.max,
      category: AndroidNotificationCategory.call,
      fullScreenIntent: true, // present over the lock screen, like a real call
      ongoing: true,
      autoCancel: false,
      actions: const [
        AndroidNotificationAction('accept', 'Accept', showsUserInterface: true),
        AndroidNotificationAction('decline', 'Decline', cancelNotification: true),
      ],
    );
    await _local.show(
      _callNotificationId,
      'Incoming call',
      caller,
      NotificationDetails(android: details),
      payload: jsonEncode(data),
    );
  }

  static void _onNotificationAction(NotificationResponse r) {
    final data = r.payload != null
        ? Map<String, dynamic>.from(jsonDecode(r.payload!) as Map)
        : <String, dynamic>{};
    _local.cancel(_callNotificationId);
    if (r.actionId == 'decline') {
      onDeclineCall?.call(data);
    } else {
      onAcceptCall?.call(data); // tap or 'accept'
    }
  }

  static Future<void> dismissIncomingCall() => _local.cancel(_callNotificationId);
}
