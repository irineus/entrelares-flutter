/// The App Links surface — `https://web.entrelares.app` is the PRODUCT's web
/// origin (the Blazor PWA today, Flutter Web after the cutover; the apex
/// `entrelares.app` is the landing). It already serves
/// `.well-known/assetlinks.json` for the store shell (F-54); the lote-1 PR in
/// `entrelares-app` adds the dev flavor's statement. Recovery e-mails point
/// here for BOTH flavors: on a device with this app installed and the domain
/// verified, Android opens the app; anywhere else the link degrades
/// gracefully to the web page. The dev Supabase project must allow this URL
/// in its auth redirect allowlist.
abstract final class DeepLinkUrls {
  static const String webOrigin = 'https://web.entrelares.app';
  static const String updatePassword = '$webOrigin/update-password';

  /// Where GoTrue sends the founder's confirmation e-mail. It lands on the web
  /// sign-in page by design: the account is not usable until the link is
  /// clicked, and that click happens in whatever mail client the person uses,
  /// often on another device.
  static const String login = '$webOrigin/login';

  /// The LANDING's origin. Legal pages live there, and that is not a detail of
  /// taste: `webOrigin` is the address changing hands in the cutover, and this
  /// app has no `/privacy` route of its own (lote 4: one copy of the legal
  /// text, opened in the browser). Pointed at `webOrigin`, these links worked
  /// only for as long as the BLAZOR app answered there — the moment the domain
  /// moved they would land on this app, which has nothing to show, and the
  /// policy would become unreachable from inside the product. The landing is a
  /// separate stack that is not moving.
  static const String landingOrigin = 'https://entrelares.app';
  static const String privacy = '$landingOrigin/privacidade';
  static const String terms = '$landingOrigin/termos';
}
