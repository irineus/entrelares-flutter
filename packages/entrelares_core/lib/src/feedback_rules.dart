/// UX-feedback mirrors — ported from the web's
/// `Entrelares/Services/ToastService.cs`. Only the pure half lives here; the
/// SnackBar presentation is the app package's.
library;

/// QA (July 2026, inherited from the web): toasts never truncate, so the
/// dismiss delay scales with the reading load instead — 3 s baseline, plus
/// 35 ms per character beyond a short message, capped at 8 s. Mirror of
/// `ToastService.ComputeDismissDelay`.
int snackDismissDelayMs(int messageLength) {
  final over = messageLength > 40 ? messageLength - 40 : 0;
  final delay = 3000 + over * 35;
  return delay > 8000 ? 8000 : delay;
}
