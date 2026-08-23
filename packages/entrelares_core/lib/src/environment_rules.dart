/// Environment Tag — mirror of the web app's `[Dev]` prefix (parity map,
/// lote 1). Every non-production build announces itself on the visible app
/// title so a tester can never mistake which backend a screen talks to;
/// production carries no tag. The flavor decides `isProduction` at compile
/// time — there is no runtime environment switch by construction.
String environmentTitlePrefix({required bool isProduction}) =>
    isProduction ? '' : '[Dev] ';

/// Which environment a BUILD targets — the rule `Env.current` inlines.
///
/// T-53 stage 4: the Android build says it with `--flavor`, but **the web
/// target has no flavors** (`flutter build web` accepts no `--flavor`), so on
/// web `appFlavor` is always null and a flavor-only rule silently resolves to
/// dev. That is harmless for `flutter test` and catastrophic for the web
/// channel: the production hostname would talk to the QA database. So the web
/// says it with `--dart-define=APP_ENV=prod`, and either channel saying `prod`
/// is enough.
///
/// The default stays the safe one: **anything that does not explicitly say
/// `prod` is dev**, which is what keeps flavor-less targets (tests, tooling)
/// off production by construction.
bool isProductionTarget({String? flavor, String appEnv = ''}) =>
    flavor == 'prod' || appEnv == 'prod';
