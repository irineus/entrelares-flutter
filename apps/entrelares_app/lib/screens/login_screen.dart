import 'dart:async';

import 'package:entrelares_core/entrelares_core.dart';
import 'package:flutter/material.dart';
import '../widgets/ui/ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../deep_link_urls.dart';
import '../widgets/app_l10n.dart';

/// Why the visitor was sent back here, so the banner reads the right message
/// (the web's `session_expired` sessionStorage flag).
enum SessionExpiredReason { none, restored, inactivity }

class LoginScreen extends StatefulWidget {
  /// Throws on failure; the screen translates the error for display.
  final Future<void> Function(String email, String password) onSignIn;

  final SessionExpiredReason expiredReason;

  final VoidCallback onForgotPassword;

  /// Opens `/register` — live since lote 4.
  final VoidCallback onSignUp;

  /// S-01 throttle state store — the web keeps it in sessionStorage; local
  /// prefs here so a process restart does not reset the clock.
  final SharedPreferences prefs;

  const LoginScreen(
      {super.key,
      required this.onSignIn,
      required this.onForgotPassword,
      required this.onSignUp,
      required this.prefs,
      this.expiredReason = SessionExpiredReason.none});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  /// Same store names as the web's sessionStorage keys.
  static const _failsKey = 'login_fails';
  static const _lockoutUntilKey = 'login_lockout_until';

  final _email = TextEditingController();
  final _password = TextEditingController();

  /// The catalog KEY of the current error, so a language switch re-renders it.
  String? _errorKey;
  bool _busy = false;

  // S-01 — progressive throttling (mirror in LoginThrottle).
  int _failedAttempts = 0;
  int _lockoutSecondsLeft = 0;
  Timer? _lockoutTicker;

  bool get _lockedOut => _lockoutSecondsLeft > 0;

  @override
  void initState() {
    super.initState();
    _failedAttempts = widget.prefs.getInt(_failsKey) ?? 0;
    final untilSeconds = widget.prefs.getInt(_lockoutUntilKey);
    if (untilSeconds != null) {
      final remaining = LoginThrottle.remainingSeconds(
          DateTime.fromMillisecondsSinceEpoch(untilSeconds * 1000, isUtc: true),
          DateTime.now().toUtc());
      if (remaining > 0) _startLockout(remaining, persist: false);
    }
  }

  @override
  void dispose() {
    _lockoutTicker?.cancel();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy || _lockedOut) return;
    setState(() {
      _busy = true;
      _errorKey = null;
    });
    try {
      await widget.onSignIn(_email.text.trim(), _password.text);
      // Success routes away from this screen (auth listener in main).
      await widget.prefs.remove(_failsKey);
      await widget.prefs.remove(_lockoutUntilKey);
    } catch (e) {
      final raw = e.toString();
      _failedAttempts++;
      await widget.prefs.setInt(_failsKey, _failedAttempts);
      final lockout = LoginThrottle.lockoutSecondsFor(_failedAttempts);
      if (lockout > 0) _startLockout(lockout);
      if (mounted) {
        setState(() {
          _errorKey = raw.contains('Invalid login credentials')
              ? K.authErrInvalidCredentials
              : K.authErrConnection;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _startLockout(int seconds, {bool persist = true}) {
    if (persist) {
      final until = DateTime.now().toUtc().add(Duration(seconds: seconds));
      widget.prefs
          .setInt(_lockoutUntilKey, until.millisecondsSinceEpoch ~/ 1000);
    }
    _lockoutTicker?.cancel();
    setState(() => _lockoutSecondsLeft = seconds);
    _lockoutTicker = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() => _lockoutSecondsLeft--);
      if (_lockoutSecondsLeft <= 0) timer.cancel();
    });
  }

  Future<void> _openWebPage(String url) async {
    // Legal pages live on the web until lote 4 ports them.
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context).l;
    final expiredText = switch (widget.expiredReason) {
      SessionExpiredReason.none => null,
      SessionExpiredReason.restored => l[KApp.sessionRestoredExpired],
      SessionExpiredReason.inactivity => l[K.loginExpiredInactivity],
    };
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(l[K.loginHeading],
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineMedium),
                const SizedBox(height: 4),
                Text(l[K.loginSubtitle],
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 24),
                if (expiredText != null) ...[
                  Text(expiredText,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error)),
                  const SizedBox(height: 12),
                ],
                AppTextField(
                  label: l[K.commonEmail],
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.email],
                ),
                const SizedBox(height: 12),
                AppTextField(
                  label: l[K.commonPassword],
                  controller: _password,
                  obscureText: true,
                  autofillHints: const [AutofillHints.password],
                  onSubmitted: (_) => _busy || _lockedOut ? null : _submit(),
                ),
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: _busy || _lockedOut ? null : _submit,
                  child: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : Text(_lockedOut
                          ? l.format(K.loginLockout, [_lockoutSecondsLeft])
                          : l[K.loginSubmit]),
                ),
                if (_errorKey != null) ...[
                  const SizedBox(height: 12),
                  Text(l[_errorKey!],
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error)),
                ],
                const SizedBox(height: 8),
                TextButton(
                  onPressed: widget.onForgotPassword,
                  child: Text(l[K.loginForgot]),
                ),
                Wrap(
                  alignment: WrapAlignment.center,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(l[K.loginSignupCta],
                        style: Theme.of(context).textTheme.bodySmall),
                    TextButton(
                      onPressed: widget.onSignUp,
                      child: Text(l[K.loginSignupLink]),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  alignment: WrapAlignment.center,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    TextButton(
                      onPressed: () => _openWebPage(DeepLinkUrls.privacy),
                      child: Text(l[K.commonPrivacyPolicy],
                          style: Theme.of(context).textTheme.bodySmall),
                    ),
                    Text('·', style: Theme.of(context).textTheme.bodySmall),
                    TextButton(
                      onPressed: () => _openWebPage(DeepLinkUrls.terms),
                      child: Text(l[K.commonTermsOfUse],
                          style: Theme.of(context).textTheme.bodySmall),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                // U-13: the picker must exist BEFORE a session does — the
                // recruited tester meets this screen first.
                const LanguagePickerRow(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
