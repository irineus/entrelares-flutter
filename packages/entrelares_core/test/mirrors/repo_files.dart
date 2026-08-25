/// Shared locator for the files the C#↔Deno mirrors used to read, ported to
/// Dart by T-56 (24/08/2026) after the emptying of `entrelares-app` took the
/// originals with it.
///
/// Why these tests read FILES instead of importing anything: the Edge Functions
/// are Deno and cannot call into Dart, so a handful of values are duplicated
/// across that boundary ON PURPOSE — the English role labels, the e-mail date
/// format, the language marker on a reset redirect, the `params` payload every
/// notification writer owes its reader. A duplication nobody checks rots
/// silently, and each rot is invisible in exactly the way that matters: the
/// output stays a valid sentence, in the wrong language or the wrong shape.
///
/// These four suites live in `entrelares_core` rather than in the app because
/// they need no Flutter and the core lane runs FIRST in `verify.yml` — a drift
/// goes red in the cheapest job there is.
library;

import 'dart:io';

/// The repository root, found by walking up from the test's working directory
/// (`dart test` runs with the package as cwd) until `supabase/functions/_shared`
/// appears.
///
/// Throws — loudly — rather than skipping. A gate that silently does nothing is
/// worse than no gate at all: it reads as coverage on every future review.
Directory repoRoot() {
  var dir = Directory.current.absolute;
  while (true) {
    if (Directory('${dir.path}/supabase/functions/_shared').existsSync()) {
      return dir;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) {
      throw StateError(
        'supabase/functions/_shared not found above ${Directory.current.path}. '
        'These mirror suites must run from inside the repository.',
      );
    }
    dir = parent;
  }
}

/// The Edge Functions' shared i18n module — the Deno side of three of the four
/// mirrors.
String i18nSource() {
  final file = File('${repoRoot().path}/supabase/functions/_shared/i18n.ts');
  if (!file.existsSync()) {
    throw StateError('Shared i18n module not found at ${file.path}.');
  }
  return file.readAsStringSync();
}

/// `supabase/migrations`, applied in filename order exactly as the CLI and CI
/// apply them.
Directory migrationsDirectory() {
  final dir = Directory('${repoRoot().path}/supabase/migrations');
  if (!dir.existsSync()) {
    throw StateError('supabase/migrations not found at ${dir.path}.');
  }
  return dir;
}

/// Reads a file under the repository root, by repo-relative path.
String repoFile(String relativePath) {
  final file = File('${repoRoot().path}/$relativePath');
  if (!file.existsSync()) {
    throw StateError('$relativePath not found at ${file.path}.');
  }
  return file.readAsStringSync();
}
