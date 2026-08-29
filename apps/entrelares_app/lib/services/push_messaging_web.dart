import 'push_messaging.dart';

/// F-09 — the web half: there is no transport, and that is a decision, not a
/// gap waiting to be filled by a flag.
///
/// Flutter Web push needs its own service worker, and `web/service-worker.js`
/// is the TOMBSTONE of the Blazor PWA's worker — it exists to unregister
/// itself and free the origin, and it must keep doing exactly that for as long
/// as any device may still carry the old install. A push handler cannot be
/// bolted onto it, so web push has to be DESIGNED (its own worker, its own
/// scope, its own QA on a channel that already carries real users). That is a
/// separate item.
///
/// Until then this stub is what the web compiles, and the point of it is that
/// `firebase_core` and `firebase_messaging` never reach the web bundle at all.
/// Everything answers "no", so the control on the Notificações screen resolves
/// to `unsupported` and says so in words — the one thing a person deserves
/// over a silently missing feature.
PushMessaging create() => const NoPushMessaging();

class NoPushMessaging implements PushMessaging {
  const NoPushMessaging();

  @override
  bool get supported => false;

  @override
  String get platformName => 'web';

  @override
  Future<bool> initialize() async => false;

  @override
  Future<PushPermission> permission() async => PushPermission.notAsked;

  @override
  Future<PushPermission> requestPermission() async => PushPermission.notAsked;

  @override
  Future<String?> token() async => null;

  @override
  Future<void> deleteToken() async {}

  @override
  Stream<String> get tokenRefreshes => const Stream.empty();

  @override
  Stream<Map<String, String>> get opened => const Stream.empty();

  @override
  Future<Map<String, String>?> initialMessage() async => null;
}
