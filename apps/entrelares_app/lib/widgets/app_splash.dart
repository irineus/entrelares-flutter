import 'package:entrelares_core/entrelares_core.dart';
import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import 'app_l10n.dart';

/// U-28 — the first screen the app shows, ported from the web's U-10 splash.
///
/// The port had a bare [CircularProgressIndicator] here. That is defensible as
/// a loading state — U-27 kept spinners exactly for waits with no known shape —
/// but this wait is not only a loading state: it is the product's first frame,
/// and the web spends it saying what the product is. A grey ring says nothing.
///
/// The web draws a small 3D calendar whose weeks alternate between two carers
/// and where two cells flip and trade colour on a loop — a day changing hands,
/// which is the whole product in one gesture. This is that, in Flutter, with
/// every colour from the tokens: the two carers are the calendar's own slot 1
/// and the swapped amber, so the splash and the calendar agree.
///
/// It respects [MediaQueryData.disableAnimations]: with animations off the card
/// sits still and the two cells simply show their end state, because a looping
/// flip is precisely what that setting exists to stop.
class AppSplash extends StatefulWidget {
  const AppSplash({super.key});

  @override
  State<AppSplash> createState() => _AppSplashState();
}

class _AppSplashState extends State<AppSplash>
    with TickerProviderStateMixin {
  /// The whole loop: two cells flip, hold, and flip back. 5.4 s is the web's
  /// own period — long enough that it reads as a calendar living its life
  /// rather than as something demanding attention.
  static const _swapPeriod = Duration(milliseconds: 5400);

  /// The card's slow rise and fall.
  static const _floatPeriod = Duration(milliseconds: 4200);

  late final AnimationController _swap =
      AnimationController(vsync: this, duration: _swapPeriod)..repeat();
  late final AnimationController _float =
      AnimationController(vsync: this, duration: _floatPeriod)..repeat(reverse: true);

  @override
  void dispose() {
    _swap.dispose();
    _float.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final l = AppL10n.of(context).l;
    final textTheme = Theme.of(context).textTheme;
    final still = MediaQuery.disableAnimationsOf(context);

    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [tokens.surfaceAlt, tokens.surface],
          ),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _floating(child: AppBrandMark(swap: _swap, still: still)),
              const SizedBox(height: Spacing.lg),
              Text(l[K.loginHeading], style: textTheme.headlineLarge),
              const SizedBox(height: Spacing.xs),
              Text(l[K.splashTagline],
                  style: textTheme.bodyMedium
                      ?.copyWith(color: tokens.textMuted)),
              const SizedBox(height: Spacing.xl),
              SizedBox(
                width: 48,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(Radii.sm),
                  child: const LinearProgressIndicator(minHeight: 3),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _floating({required Widget child}) => AnimatedBuilder(
        animation: _float,
        builder: (context, inner) {
          if (MediaQuery.disableAnimationsOf(context)) return inner!;
          final t = Curves.easeInOut.transform(_float.value);
          return Transform.translate(offset: Offset(0, -8 * t), child: inner);
        },
        child: child,
      );
}

/// The product's mark: a little month whose weeks alternate between two carers
/// and where two cells trade colour.
///
/// Shared with the login screen, which shows it STILL ([swap] left null) — the
/// same drawing in both places is what makes it read as a mark rather than as
/// an illustration one screen happens to have.
class AppBrandMark extends StatelessWidget {
  /// The 5.4 s loop that flips the two trading cells. Null on the login screen:
  /// nothing is loading there, so nothing should be moving.
  final Animation<double>? swap;

  /// Forced still by the platform's reduce-motion setting.
  final bool still;

  /// The card's width. The splash gives it room; the login screen wants a mark,
  /// not a hero.
  final double width;

  const AppBrandMark({super.key, this.swap, this.still = false, this.width = 168});

  /// Which cells are blank at the start and end of the month, so the mark reads
  /// as a real month rather than as a full rectangle. Same shape as the web's.
  static const _blankLeading = 2;
  static const _blankTrailing = 2;
  static const _rows = 5;

  /// The two cells that change hands — one in the second week, one in the
  /// third, so the eye catches the exchange rather than a single blink.
  static const _swapA = 3 * 7 + 3;
  static const _swapB = 2 * 7 + 3;

  /// The cell the month is "on".
  static const _today = 7 + 2;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Container(
      width: width,
      padding: const EdgeInsets.all(Spacing.sm + Spacing.xs),
      decoration: BoxDecoration(
        color: tokens.surfaceAlt,
        borderRadius: BorderRadius.circular(Radii.lg),
        border: Border.all(color: tokens.outline),
        boxShadow: [
          BoxShadow(
            color: tokens.scrim,
            blurRadius: 24,
            spreadRadius: -12,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // The header bar: two dots and a rule, standing in for the month
          // name. Deliberately WORDLESS — the splash paints before the reader's
          // language is resolved, and a hardcoded "Julho" would be a literal.
          Row(
            children: [
              Expanded(
                child: Container(
                  height: 4,
                  decoration: BoxDecoration(
                    color: tokens.outline,
                    borderRadius: BorderRadius.circular(Radii.sm),
                  ),
                ),
              ),
              const SizedBox(width: Spacing.sm),
              for (var i = 0; i < 2; i++) ...[
                Container(
                  width: 5,
                  height: 5,
                  decoration: BoxDecoration(
                      color: tokens.outline, shape: BoxShape.circle),
                ),
                const SizedBox(width: 3),
              ],
            ],
          ),
          const SizedBox(height: Spacing.sm),
          for (var row = 0; row < _rows; row++)
            Padding(
              padding: EdgeInsets.only(top: row == 0 ? 0 : 3),
              child: Row(
                children: [
                  for (var col = 0; col < 7; col++)
                    Expanded(
                      child: Padding(
                        padding: EdgeInsets.only(left: col == 0 ? 0 : 3),
                        child: _cell(context, row * 7 + col, row),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _cell(BuildContext context, int index, int row) {
    final tokens = context.tokens;
    final isBlank = index < _blankLeading ||
        index >= _rows * 7 - _blankTrailing;
    if (isBlank) return const AspectRatio(aspectRatio: 1, child: SizedBox());

    // Weeks alternate between the two carers — the rhythm a rotation has.
    final carer = tokens.slot(1).tone.solid;
    final other = tokens.swapped.tone.solid;
    final base = row.isEven ? carer : other;

    final isSwapA = index == _swapA;
    final isSwapB = index == _swapB;
    if ((!isSwapA && !isSwapB) || swap == null) {
      return _square(context, base, ringed: index == _today);
    }

    return AnimatedBuilder(
      animation: swap!,
      builder: (context, _) {
        // The second half of the loop shows the traded colour; the flip itself
        // is the cell collapsing to a line and opening again on the new one.
        final t = still ? 1.0 : swap!.value;
        final traded = t >= 0.48 && t < 0.94;
        final flipping =
            !still && ((t >= 0.38 && t < 0.58) || (t >= 0.86 && t < 1.0));
        final colour = traded
            ? (isSwapA ? other : carer)
            : (isSwapA ? carer : other);
        return Transform(
          alignment: Alignment.center,
          transform: Matrix4.identity()..scaleByDouble(1.0, flipping ? 0.08 : 1.0, 1.0, 1.0),
          child: _square(context, colour, ringed: index == _today),
        );
      },
    );
  }

  Widget _square(BuildContext context, Color colour, {bool ringed = false}) =>
      AspectRatio(
        aspectRatio: 1,
        child: Container(
          decoration: BoxDecoration(
            color: colour,
            borderRadius: BorderRadius.circular(Radii.sm),
            border: ringed
                ? Border.all(color: context.tokens.text, width: 1.5)
                : null,
          ),
        ),
      );
}
