// T-53 stage 4 — the gate of the WEB CHANNEL, cut to the same pattern as
// `no_color_literal_test`: files that only matter when they are SERVED cannot
// be proven by running the app, so they are proven as sources.
//
// Everything asserted here is something whose absence is silent until it is
// expensive: a build that quietly targets the QA project, a deep link that
// 404s on reload, an App Link that stops verifying on every installed phone,
// or an installed PWA that keeps serving the app this one replaced.
import 'dart:convert';
import 'dart:io';

import 'package:entrelares_app/deep_link_urls.dart';
import 'package:entrelares_app/env.dart';
import 'package:flutter_test/flutter_test.dart';

File _web(String name) => File('web/$name');
File _workflow() => File('../../.github/workflows/verify.yml');
File _androidManifest() =>
    File('android/app/src/main/AndroidManifest.xml');

void main() {
  group('_redirects (SPA fallback)', () {
    test('every unmatched path falls back to index.html with a 200', () {
      final rules = _web('_redirects').readAsStringSync();

      expect(
        RegExp(r'^/\*\s+/index\.html\s+200\s*$', multiLine: true)
            .hasMatch(rules),
        isTrue,
        reason: 'without this rule a reload of /family — or an invitation '
            'deep link — is a CDN 404 before the app boots',
      );
    });
  });

  group('the legal pages, after the host changes hands', () {
    test('the app links to the landing, not to the host it is taking over', () {
      // This app has no `/privacy` route (lote 4: one copy of the text, opened
      // in the browser). Pointing the link at the address being handed over
      // would make the policy unreachable from inside the product the moment
      // the domain moved — and nothing would fail until then.
      expect(DeepLinkUrls.privacy, startsWith(DeepLinkUrls.landingOrigin));
      expect(DeepLinkUrls.terms, startsWith(DeepLinkUrls.landingOrigin));
      expect(DeepLinkUrls.landingOrigin, isNot(DeepLinkUrls.webOrigin));
    });

    test('and the old paths still lead somewhere', () {
      // Links already out there — an e-mail, a bookmark, the old client —
      // name these paths on the host this channel now answers for.
      final rules = _web('_redirects').readAsStringSync();
      for (final path in const ['/privacy', '/terms']) {
        final rule = RegExp(r'^' + RegExp.escape(path) + r'\s+(\S+)\s+301',
                multiLine: true)
            .firstMatch(rules);
        expect(rule, isNotNull,
            reason: '$path must redirect, not fall into the SPA catch-all');
        expect(rule!.group(1), startsWith(DeepLinkUrls.landingOrigin));
      }
      // Order is the whole trick: first match wins in `_redirects`.
      expect(rules.indexOf('/privacy'), lessThan(rules.indexOf('/*')));
    });
  });

  group('_headers', () {
    late String headers;

    setUp(() => headers = _web('_headers').readAsStringSync());

    test('the CSP allows what CanvasKit needs and nothing more', () {
      final csp = RegExp(r'Content-Security-Policy: (.+)')
          .firstMatch(headers)
          ?.group(1);
      expect(csp, isNotNull, reason: 'the web channel ships with a CSP');

      // WebAssembly and blob workers: the engine does not run without them.
      expect(csp, contains("'wasm-unsafe-eval'"));
      expect(csp, contains('worker-src'));
      // What the app talks to — Supabase (REST + Realtime) and the collector.
      expect(csp, contains('https://*.supabase.co'));
      expect(csp, contains('wss://*.supabase.co'));
      expect(csp, contains('https://cloud.umami.is'));
      expect(csp, contains("frame-ancestors 'none'"));

      // The font fallback the engine fetches when the embedded Inter has no
      // glyph. Without it the product's emoji vocabulary is tofu on the web.
      expect(csp, contains('https://fonts.gstatic.com'));

      // Blazor WASM needed `unsafe-eval`; CanvasKit does not, and inheriting
      // it would be a permission granted for a reason that no longer exists.
      expect(csp, isNot(contains("'unsafe-eval'")));
      // CanvasKit is served from THIS origin (`--no-web-resources-cdn`). Fonts
      // may come from a third party; EXECUTABLE code may not — a gstatic host
      // inside script-src would mean the build lost that flag.
      final scriptSrc = RegExp(r'script-src ([^;]+)').firstMatch(csp!)!.group(1);
      expect(scriptSrc, isNot(contains('gstatic')));
    });

    test('the files whose staleness breaks a deploy are uncacheable', () {
      for (final path in const [
        '/service-worker.js',
        '/flutter_service_worker.js',
        '/flutter_bootstrap.js',
        '/index.html',
      ]) {
        final block = RegExp('${RegExp.escape(path)}\\r?\\n(.*)')
            .firstMatch(headers)
            ?.group(1);
        expect(block, contains('no-store'),
            reason: '$path must never come from an HTTP cache');
      }
    });
  });

  group('service-worker.js (the Blazor tombstone)', () {
    late String worker;

    setUp(() => worker = _web('service-worker.js').readAsStringSync());

    test('it clears the old caches, unregisters and reloads the windows', () {
      expect(worker, contains('caches.delete'));
      expect(worker, contains('registration.unregister'));
      expect(worker, contains('skipWaiting'));
      expect(worker, contains('client.navigate'));
    });

    test('it handles no fetch — it is a tombstone, not a cache', () {
      // A fetch handler here would make this worker the app's network layer,
      // which is precisely the job it exists to take AWAY from the old one.
      expect(worker, isNot(contains("addEventListener('fetch'")));
    });
  });

  group('.well-known/assetlinks.json', () {
    test('it authorizes the packages the Android build claims', () {
      final statements = jsonDecode(
        _web('.well-known/assetlinks.json').readAsStringSync(),
      ) as List<dynamic>;

      Map<String, dynamic> targetOf(String package) => statements
          .cast<Map<String, dynamic>>()
          .map((s) => s['target'] as Map<String, dynamic>)
          .firstWhere((t) => t['package_name'] == package,
              orElse: () => throw StateError('missing statement: $package'));

      // The store app. It carries TWO fingerprints — the upload key and the
      // one Play's app signing emits — and dropping either breaks App Link
      // verification on every installed phone.
      final store = targetOf('com.entrelares.app');
      expect((store['sha256_cert_fingerprints'] as List).length, 2);

      // The dev flavor, so QA can verify its own links (lote 1).
      targetOf('com.entrelares.flutter');
      // The legacy TWA package, still installed on devices until T-52.
      targetOf('com.guardacompartilhada.app');
    });

    test('it is served from the host the Android build verifies against', () {
      // The file only does anything at the hostname `autoVerify` names, which
      // is the hostname this channel is taking over. If one moves without the
      // other, invitation and recovery links stop opening in the app.
      final manifest = _androidManifest().readAsStringSync();
      expect(manifest, contains('android:host="${Env.prod.webHostname}"'));
      expect(Env.prod.webHostname, 'web.entrelares.app');
    });
  });

  group('manifest.json', () {
    test('it installs at the root and points at the store app', () {
      final manifest =
          jsonDecode(_web('manifest.json').readAsStringSync())
              as Map<String, dynamic>;

      expect(manifest['start_url'], '/');
      expect(manifest['scope'], '/');
      expect(manifest['id'], '/');
      expect(manifest['lang'], 'pt-BR');
      final related = manifest['related_applications'] as List<dynamic>;
      expect(
        related.cast<Map<String, dynamic>>().map((a) => a['id']),
        contains(Env.prod.androidPackage),
      );
    });
  });

  group('the URL strategy', () {
    test('the web channel serves real paths, not `/#/`', () {
      // A hash router would make `_redirects` pointless AND would drop the
      // token of an invitation link, which lives in the PATH — the failure
      // would only show up after the domain move, on a real invitation.
      final main = File('lib/main.dart').readAsStringSync();
      expect(main, contains('usePathUrlStrategy()'));
    });
  });

  group('the deploy workflow', () {
    late String workflow;

    setUp(() => workflow = _workflow().readAsStringSync());

    test('the published build says APP_ENV=prod', () {
      // THE assertion of this file. `flutter build web` has no `--flavor`, so
      // this define is the only thing standing between the production
      // hostname and the QA database.
      final build = RegExp(r'flutter build web --release[^\n]*APP_ENV=prod')
          .hasMatch(workflow);
      expect(build, isTrue,
          reason: 'the deploy must build with --dart-define=APP_ENV=prod');
    });

    test('the published build serves CanvasKit from its own origin', () {
      expect(workflow, contains('--no-web-resources-cdn'));
    });

    test('publishing waits for the gate, and only from main', () {
      final job = workflow.substring(workflow.indexOf('  deploy-web:'));
      expect(job, contains('needs: verify'));
      expect(job, contains("github.ref_name == 'main'"));
      expect(job, contains('wrangler pages deploy build/web'));
    });
  });
}
