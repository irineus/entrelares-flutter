/// Environment Tag — mirror of the web app's `[Dev]` prefix (parity map,
/// lote 1). Every non-production build announces itself on the visible app
/// title so a tester can never mistake which backend a screen talks to;
/// production carries no tag. The flavor decides `isProduction` at compile
/// time — there is no runtime environment switch by construction.
String environmentTitlePrefix({required bool isProduction}) =>
    isProduction ? '' : '[Dev] ';
