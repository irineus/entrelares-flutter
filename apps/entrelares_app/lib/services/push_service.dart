import 'dart:async';

import 'package:entrelares_core/entrelares_core.dart';
import 'package:flutter/foundation.dart';

import 'custody_data_source.dart';
import 'push_messaging.dart';

/// F-09 — the device's side of push: the permission, the token's lifetime, and
/// where a tap lands.
///
/// **The rules are not here.** Which of the four states the person is in, and
/// whether the app may prompt or register silently, is [PushEnrollment] in the
/// pure package. This class is the orchestration, and it reaches the platform
/// only through [PushMessaging] — which is what lets a suite drive it.
///
/// **Nothing here ever prompts on its own.** Android 13+ shows the permission
/// dialog ONCE per install and a refusal is only reversible in Settings, so the
/// prompt is a one-shot resource: it is spent by [enable], reachable only from
/// a gesture, after the person has a reason to want it. [start] runs on every
/// authenticated session and is deliberately silent — it repairs a registration
/// for someone who already said yes, and does nothing otherwise.
///
/// **No background isolate.** The server sends a `notification` payload, which
/// the OS renders on its own with the app backgrounded or dead, so there is
/// nothing for a `@pragma('vm:entry-point')` handler to do. In the foreground
/// the app is already live on Realtime, and an OS notification over a screen
/// that just updated itself would be noise.
class PushService extends ChangeNotifier {
  final CustodyDataSource _dataSource;
  final PushMessaging _messaging;

  /// Where a tapped notification should land. The payload's values are data
  /// (ids and an ISO date), never text to render.
  void Function(Map<String, String> data)? onOpen;

  PushService(this._dataSource, {PushMessaging? messaging})
      : _messaging = messaging ?? createPushMessaging();

  /// True once the transport has come up. False on the web, and on a build or
  /// device where it could not start.
  bool _ready = false;

  PushState _state = PushState.unsupported;
  PushState get state => _state;

  int? _profileId;
  String? _token;
  StreamSubscription<String>? _tokenRefresh;
  StreamSubscription<Map<String, String>>? _opened;

  Future<void>? _initialization;

  /// Called once, at construction time. Never throws.
  ///
  /// The future is KEPT rather than awaited by the caller, and [start] awaits
  /// it. Without that, the two are a race the session usually wins by luck: the
  /// auth gate is a network round trip and this is local, so `start` would
  /// normally run second — but "normally" is how a feature ends up silently off
  /// for the subset of people whose transport took a moment longer.
  Future<void> initialize() {
    return _initialization ??= () async {
      _ready = _messaging.supported && await _messaging.initialize();
    }();
  }

  /// Whether this BUILD has a push transport at all — false on the web. Read
  /// by the U-23 checklist, which must not offer a step it cannot finish.
  bool get supported => _messaging.supported;

  bool get _usable => _messaging.supported && _ready;

  /// Entering the authenticated phase. Reads the REAL state — the OS
  /// permission and whether a row exists — and repairs a registration when the
  /// person has already granted it. Never prompts.
  Future<void> start(int profileId) async {
    _profileId = profileId;
    await initialize();
    if (!_usable) {
      _set(PushState.unsupported);
      return;
    }

    try {
      final permission = await _messaging.permission();
      var hasRow = await _dataSource.hasPushSubscription(profileId);

      if (PushEnrollment.shouldRegisterSilently(
        platformSupported: true,
        permissionGranted: permission == PushPermission.granted,
        hasSubscription: hasRow,
      )) {
        hasRow = await _register(profileId);
      }

      _set(_resolve(permission, hasRow));
      await _listen();
    } catch (error) {
      // A device with no Play Services, an offline start, a transport that
      // refuses: none of it is worth a broken session. The control reads "off"
      // and the person can try again.
      debugPrint('[push] start failed: $error');
      _set(PushState.off);
    }
  }

  /// Leaving the authenticated phase. Unregisters THIS device: the phone may be
  /// handed to the other parent, and a token left behind would keep delivering
  /// the previous account's notices.
  Future<void> stop() async {
    await _tokenRefresh?.cancel();
    _tokenRefresh = null;
    await _opened?.cancel();
    _opened = null;

    final token = _token;
    _token = null;
    _profileId = null;
    _set(_messaging.supported ? PushState.off : PushState.unsupported);

    if (token == null) return;
    try {
      await _dataSource.deletePushToken(token);
    } catch (error) {
      // Best effort, and safe to lose: the token dies on the server's next
      // send anyway (FCM answers UNREGISTERED once the app is gone), and a
      // sign-out must never wait on the network — pilot lesson 1.3.
      debugPrint('[push] stop could not drop the token: $error');
    }
  }

  /// The gesture path: ask the OS, then register. Returns the state the control
  /// should now show.
  Future<PushState> enable() async {
    final profileId = _profileId;
    if (!_usable || profileId == null) return _state;

    try {
      final permission = PushEnrollment.canPrompt(_state)
          ? await _messaging.requestPermission()
          : await _messaging.permission();

      final granted = permission == PushPermission.granted;
      final hasRow = granted ? await _register(profileId) : false;

      _set(_resolve(permission, hasRow));
      if (granted) await _listen();
    } catch (error) {
      debugPrint('[push] enable failed: $error');
      _set(PushState.off);
    }
    return _state;
  }

  /// Turning push off from the app. The OS permission is left alone — it is the
  /// person's, and revoking it is Settings' job — so this drops the
  /// registration, which is the thing the app actually controls.
  Future<void> disable() async {
    final token = _token;
    try {
      if (token != null) await _dataSource.deletePushToken(token);
      await _messaging.deleteToken();
    } catch (error) {
      debugPrint('[push] disable failed: $error');
    }
    _token = null;
    _set(PushState.off);
  }

  PushState _resolve(PushPermission permission, bool hasSubscription) =>
      PushEnrollment.resolve(
        platformSupported: true,
        permissionGranted: permission == PushPermission.granted,
        permissionDeniedForGood: permission == PushPermission.denied,
        hasSubscription: hasSubscription,
      );

  Future<bool> _register(int profileId) async {
    final token = await _messaging.token();
    if (token == null) return false;
    _token = token;
    await _dataSource.registerPushToken(
      myProfileId: profileId,
      token: token,
      platform: _messaging.platformName,
    );
    return true;
  }

  Future<void> _listen() async {
    // The transport rotates a token on its own schedule (a restore to a new
    // device, a reinstall, its own housekeeping). Missing the rotation is the
    // classic silent break: every layer keeps reporting success while the
    // server holds an address nobody answers.
    _tokenRefresh ??= _messaging.tokenRefreshes.listen(_onTokenRotated);
    _opened ??= _messaging.opened.listen((data) => onOpen?.call(data));

    // The app opened FROM a notification while it was dead — that message waits
    // here rather than on the stream, and is delivered exactly once.
    final initial = await _messaging.initialMessage();
    if (initial != null) onOpen?.call(initial);
  }

  Future<void> _onTokenRotated(String token) async {
    final profileId = _profileId;
    if (profileId == null) return;
    final previous = _token;
    _token = token;
    try {
      await _dataSource.registerPushToken(
        myProfileId: profileId,
        token: token,
        platform: _messaging.platformName,
      );
      if (previous != null && previous != token) {
        await _dataSource.deletePushToken(previous);
      }
    } catch (error) {
      debugPrint('[push] token refresh not persisted: $error');
    }
  }

  void _set(PushState next) {
    if (next == _state) return;
    _state = next;
    notifyListeners();
  }

  @override
  void dispose() {
    _tokenRefresh?.cancel();
    _opened?.cancel();
    super.dispose();
  }
}
