import 'package:entrelares_core/entrelares_core.dart';
import 'package:flutter/material.dart';
import 'ui/ui.dart';

import '../services/sudo_service.dart';
import 'app_l10n.dart';

/// S-10 — the 🔐 password re-entry sheet, port of `SudoPrompt.razor`.
///
/// Returns true when the window is now open, false when the user backed out.
/// The web splits chrome and content across two files for a CSS-isolation
/// reason that does not exist here, so this is one widget; the Escape/back
/// dismissal the web only wired on the Profile page works on every caller.
Future<bool> showSudoSheet({
  required BuildContext context,
  required SudoService sudo,
}) async {
  final granted = await showAppSheet<bool>(
    context: context,
    builder: (context) => Padding(
      padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom),
      child: _SudoSheet(sudo: sudo),
    ),
  );
  return granted ?? false;
}

/// The two-layer S-10 gate, in one call: ask BEFORE acting when the client
/// knows it is not elevated, and ask AGAIN when the action itself comes back
/// with the `ELEVATION_REQUIRED:` marker.
///
/// The second layer is what makes this correct rather than merely optimistic —
/// the window can expire between the check and the RPC, and a device with a
/// drifted clock never gets the first layer right at all.
///
/// [action] must surface the server's error by throwing it. Returns true when
/// the action ran to completion; false when the user dismissed the prompt.
/// Any non-elevation failure is rethrown for the caller to translate.
Future<bool> runWithSudo({
  required BuildContext context,
  required SudoService sudo,
  required Future<void> Function() action,
}) async {
  if (!sudo.isElevated) {
    if (!await showSudoSheet(context: context, sudo: sudo)) return false;
  }

  try {
    await action();
    return true;
  } catch (error) {
    if (!SudoRules.isElevationRequired(error)) rethrow;
    // The server disagreed with our optimism — prompt and retry ONCE.
    if (!context.mounted) return false;
    if (!await showSudoSheet(context: context, sudo: sudo)) return false;
    await action();
    return true;
  }
}

class _SudoSheet extends StatefulWidget {
  final SudoService sudo;

  const _SudoSheet({required this.sudo});

  @override
  State<_SudoSheet> createState() => _SudoSheetState();
}

class _SudoSheetState extends State<_SudoSheet> {
  final _controller = TextEditingController();
  bool _obscured = true;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _confirm(Localization l) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final message = await widget.sudo.elevate(_controller.text, l);
    if (!mounted) return;
    // The password never survives an attempt — right or wrong (web parity).
    _controller.clear();
    if (message == null) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _busy = false;
      _error = message;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context).l;
    final cooling = widget.sudo.isCoolingDown;
    final canSubmit = !_busy && !cooling && _controller.text.isNotEmpty;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l[K.sudoTitle],
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(l[K.sudoHint],
                style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 16),
            AppTextField(
              label: l[K.sudoCurrentPassword],
              controller: _controller,
              autofocus: true,
              obscureText: _obscured,
              enabled: !_busy && !cooling,
              errorText: _error,
              suffixIcon: IconButton(
                tooltip: l[
                    _obscured ? K.commonShowPassword : K.commonHidePassword],
                icon:
                    Icon(_obscured ? Icons.visibility : Icons.visibility_off),
                onPressed: () => setState(() => _obscured = !_obscured),
              ),
              onChanged: (_) => setState(() {}),
              onSubmitted: canSubmit ? (_) => _confirm(l) : null,
            ),
            const SizedBox(height: 12),
            Text(l[K.sudoForgot],
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed:
                      _busy ? null : () => Navigator.of(context).pop(false),
                  child: Text(l[K.commonCancel]),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: canSubmit ? () => _confirm(l) : null,
                  child: Text(l[K.sudoConfirm]),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
