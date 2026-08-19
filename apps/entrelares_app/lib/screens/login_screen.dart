import 'package:entrelares_core/entrelares_core.dart';
import 'package:flutter/material.dart';

import '../widgets/app_l10n.dart';

class LoginScreen extends StatefulWidget {
  /// Throws on failure; the screen translates the error for display.
  final Future<void> Function(String email, String password) onSignIn;

  /// True when the gate cleared a restored-but-dead session (lesson 1.1).
  final bool showSessionExpiredNotice;

  const LoginScreen(
      {super.key,
      required this.onSignIn,
      this.showSessionExpiredNotice = false});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();

  /// The catalog KEY of the current error, so a language switch re-renders it.
  String? _errorKey;
  bool _busy = false;

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _errorKey = null;
    });
    try {
      await widget.onSignIn(_email.text.trim(), _password.text);
      // Success routes away from this screen (auth listener in main).
    } catch (e) {
      final raw = e.toString();
      setState(() {
        _errorKey = raw.contains('Invalid login credentials')
            ? K.authErrInvalidCredentials
            : K.authErrConnection;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context).l;
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
                if (widget.showSessionExpiredNotice) ...[
                  Text(l[KApp.sessionRestoredExpired],
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error)),
                  const SizedBox(height: 12),
                ],
                TextField(
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.email],
                  decoration: InputDecoration(labelText: l[K.commonEmail]),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _password,
                  obscureText: true,
                  autofillHints: const [AutofillHints.password],
                  decoration: InputDecoration(labelText: l[K.commonPassword]),
                  onSubmitted: (_) => _busy ? null : _submit(),
                ),
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: _busy ? null : _submit,
                  child: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : Text(l[K.loginSubmit]),
                ),
                if (_errorKey != null) ...[
                  const SizedBox(height: 12),
                  Text(l[_errorKey!],
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error)),
                ],
                const SizedBox(height: 16),
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
