import 'dart:async';

import 'package:entrelares_core/entrelares_core.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'env.dart';
import 'screens/calendar_screen.dart';
import 'screens/login_screen.dart';
import 'services/session_gate.dart';
import 'services/supabase_custody_data_source.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // publishableKey is just the `apikey` header value — it accepts the legacy
  // anon JWT dev still uses (until S-17) as well as the new sb_publishable_…
  // key prod already has, so the S-16 shape ports for free (stage 0).
  await Supabase.initialize(
    url: Env.current.supabaseUrl,
    publishableKey: Env.current.supabaseKey,
  );
  runApp(const EntrelaresApp());
}

class EntrelaresApp extends StatefulWidget {
  const EntrelaresApp({super.key});

  @override
  State<EntrelaresApp> createState() => _EntrelaresAppState();
}

enum _Route { gate, login, calendar }

class _EntrelaresAppState extends State<EntrelaresApp> {
  late final SessionGate _gate;
  _Route _route = _Route.gate;
  String? _loginNotice;
  StreamSubscription<AuthState>? _authSub;

  SupabaseClient get _client => Supabase.instance.client;

  @override
  void initState() {
    super.initState();
    _gate = SessionGate(_client.auth);
    _openGate();
    // Pilot lesson 1.1 (second half): when the session dies MID-USE, return
    // to login instead of letting every call fail 42501.
    _authSub = _client.auth.onAuthStateChange.listen((state) {
      if (state.event == AuthChangeEvent.signedOut && mounted) {
        setState(() => _route = _Route.login);
      }
    });
  }

  @override
  void dispose() {
    _authSub?.cancel();
    super.dispose();
  }

  Future<void> _openGate() async {
    // Lesson 1.1: a restored session proves nothing — validate with
    // refreshSession() BEFORE routing (Blazor got this for free via
    // forceLoad; Flutter has no equivalent).
    final hadSession = _client.auth.currentSession != null;
    final alive = await _gate.validateRestoredSession();
    if (!mounted) return;
    setState(() {
      _loginNotice =
          !alive && hadSession ? 'Sua sessão anterior expirou.' : null;
      _route = alive ? _Route.calendar : _Route.login;
    });
  }

  Future<void> _signIn(String email, String password) async {
    await _client.auth.signInWithPassword(email: email, password: password);
    if (mounted) setState(() => _route = _Route.calendar);
  }

  Future<void> _signOut() async {
    await _gate.signOutSafely();
    // Lesson 1.3: navigate ALWAYS (the auth listener also fires on success).
    if (mounted) {
      setState(() {
        _loginNotice = null;
        _route = _Route.login;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title:
          '${environmentTitlePrefix(isProduction: Env.current.isProduction)}'
          'Entrelares',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF4F46E5)),
        useMaterial3: true,
      ),
      home: switch (_route) {
        _Route.gate =>
          const Scaffold(body: Center(child: CircularProgressIndicator())),
        _Route.login => LoginScreen(onSignIn: _signIn, notice: _loginNotice),
        _Route.calendar => CalendarScreen(
            dataSource: SupabaseCustodyDataSource(_client),
            onSignOut: _signOut,
          ),
      },
    );
  }
}
