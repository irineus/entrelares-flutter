/// U-13 (T-53 port) — keys that exist ONLY in the Flutter app, hand-written.
///
/// The main catalogs (`k.dart`, `strings_pt_br.dart`, `strings_en.dart`) are
/// GENERATED mirrors of the web app's — they must never gain a key the web
/// catalog does not have, or the re-sync tool would silently drop it. Strings
/// born in this client (the pilot's session-gate messages, the native day
/// sheet's read view) live here instead, under an `app.` prefix so the two
/// namespaces cannot collide. Same parity gates apply (localization_test).
library;

abstract final class KApp {
  // ── Session gate (pilot lessons 1.1/1.2) ──
  static const String sessionRestoredExpired = 'app.session.restoredExpired';
  static const String sessionExpired = 'app.session.expired';

  // ── Calendar screen ──
  static const String errCalendarLoad = 'app.calendar.loadError';

  // ── Day sheet (native read view — the web's editor has no read mode) ──
  static const String sheetNoResponsible = 'app.sheet.noResponsible';
  static const String sheetResponsible = 'app.sheet.responsible';
  static const String sheetSwappedSuffix = 'app.sheet.swappedSuffix';
  static const String sheetTransitionAt = 'app.sheet.transitionAt';
  static const String sheetTransition = 'app.sheet.transition';
  static const String sheetNote = 'app.sheet.note';
  static const String sheetWhoQuestion = 'app.sheet.whoQuestion';
  static const String sheetSave = 'app.sheet.save';
  static const String errDaySave = 'app.sheet.saveError';

  // ── Save errors (mirrors of TranslateSaveError's inline literals, which
  //    the frozen web app never extracted) ──
  static const String errSwapPendingExists = 'app.save.swapPendingExists';
  static const String errConcurrentSaveRetry = 'app.save.concurrentRetry';

  // ── F-40 proactive hint (lote 2) — the web never warns upfront (the
  //    trigger refuses and the text propagates); this native editor explains
  //    BEFORE the attempt, so the copy mirrors the trigger's own messages ──
  static const String editorRetroBeyondFree = 'app.editor.retroBeyondFree';
  static const String editorRetroBeyondPremium =
      'app.editor.retroBeyondPremium';

  // ── Navigation shell (lote 1) — screens the later batches fill in ──
  static const String shellUnderConstructionTitle =
      'app.shell.underConstructionTitle';
  static const String shellUnderConstructionBody =
      'app.shell.underConstructionBody';

  /// See `K.allKeys`.
  static const List<String> allKeys = [
    sessionRestoredExpired,
    sessionExpired,
    errCalendarLoad,
    sheetNoResponsible,
    sheetResponsible,
    sheetSwappedSuffix,
    sheetTransitionAt,
    sheetTransition,
    sheetNote,
    sheetWhoQuestion,
    sheetSave,
    errDaySave,
    errSwapPendingExists,
    errConcurrentSaveRetry,
    editorRetroBeyondFree,
    editorRetroBeyondPremium,
    shellUnderConstructionTitle,
    shellUnderConstructionBody,
  ];
}

/// PT-BR — the original text of this client, verbatim from the stage-1 spike.
abstract final class StringsAppPtBr {
  static const Map<String, String> values = {
    KApp.sessionRestoredExpired: 'Sua sessão anterior expirou.',
    KApp.sessionExpired: 'Sessão expirada — saia e entre novamente.',
    KApp.errCalendarLoad: 'Não foi possível carregar o calendário.',
    KApp.sheetNoResponsible: 'Dia sem responsável definido.',
    KApp.sheetResponsible: 'Responsável: {0}',
    KApp.sheetSwappedSuffix: ' (trocado)',
    KApp.sheetTransitionAt: 'Dia de transição — troca às {0}',
    KApp.sheetTransition: 'Dia de transição',
    KApp.sheetNote: 'Observação: {0}',
    KApp.sheetWhoQuestion: 'Quem fica com a criança neste dia?',
    KApp.sheetSave: 'Salvar',
    KApp.errDaySave: 'Não foi possível salvar o dia.',
    KApp.errSwapPendingExists:
        'Já existe uma solicitação pendente para este dia — o calendário foi '
            'atualizado.',
    KApp.errConcurrentSaveRetry:
        'Outro responsável salvou este dia primeiro — atualize o calendário e '
            'tente novamente.',
    KApp.editorRetroBeyondFree:
        'O plano gratuito corrige apenas os últimos {0} dias. Ative o Premium '
            'para corrigir dias mais antigos (até {1} meses).',
    KApp.editorRetroBeyondPremium:
        'Correções retroativas vão até {0} meses atrás.',
    KApp.shellUnderConstructionTitle: 'Em construção',
    KApp.shellUnderConstructionBody:
        'Esta tela chega em uma próxima atualização.',
  };
}

/// EN — same rules as the main catalog: placeholder SETS match PT-BR.
abstract final class StringsAppEn {
  static const Map<String, String> values = {
    KApp.sessionRestoredExpired: 'Your previous session expired.',
    KApp.sessionExpired: 'Session expired — sign out and sign in again.',
    KApp.errCalendarLoad: 'Could not load the calendar.',
    KApp.sheetNoResponsible: 'No caregiver assigned to this day.',
    KApp.sheetResponsible: 'Caregiver: {0}',
    KApp.sheetSwappedSuffix: ' (swapped)',
    KApp.sheetTransitionAt: 'Transition day — handoff at {0}',
    KApp.sheetTransition: 'Transition day',
    KApp.sheetNote: 'Note: {0}',
    KApp.sheetWhoQuestion: 'Who has the child on this day?',
    KApp.sheetSave: 'Save',
    KApp.errDaySave: 'Could not save the day.',
    KApp.errSwapPendingExists:
        'There is already a pending request for this day — the calendar has '
            'been refreshed.',
    KApp.errConcurrentSaveRetry:
        'The other caregiver saved this day first — refresh the calendar and '
            'try again.',
    KApp.editorRetroBeyondFree:
        'The free plan corrects only the last {0} days. Activate Premium to '
            'correct older days (up to {1} months).',
    KApp.editorRetroBeyondPremium:
        'Retroactive corrections reach up to {0} months back.',
    KApp.shellUnderConstructionTitle: 'Under construction',
    KApp.shellUnderConstructionBody:
        'This screen arrives in an upcoming update.',
  };
}
