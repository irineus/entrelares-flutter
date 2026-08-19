import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'env.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // publishableKey is just the `apikey` header value — it accepts the legacy
  // anon JWT dev still uses (until S-17) as well as the new sb_publishable_…
  // key prod already has, so the S-16 shape ports for free (stage 0).
  await Supabase.initialize(
    url: Env.supabaseUrl,
    publishableKey: Env.supabaseKey,
  );
  runApp(const EntrelaresApp());
}

class EntrelaresApp extends StatelessWidget {
  const EntrelaresApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Entrelares',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF4F46E5)),
        useMaterial3: true,
      ),
      // PR 1 (foundation): a sanity screen only. PR 2 replaces this with the
      // session gate (refreshSession BEFORE routing — pilot lesson 1) and the
      // calendar slice.
      home: const _FoundationScreen(),
    );
  }
}

class _FoundationScreen extends StatelessWidget {
  const _FoundationScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Entrelares — spike T-53')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('Fundação pronta.'),
            const SizedBox(height: 8),
            Text('Ambiente: ${Env.name}'),
          ],
        ),
      ),
    );
  }
}
