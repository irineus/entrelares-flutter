/// Mirror of the save-error translation cases in
/// `Entrelares.Tests/CalendarHelpersTests.cs` (QA S-11 / T-33 / T-35) plus
/// the pilot's session-expiry mapping (`entrelares-console`, F-58 QA 1.2).
library;

import 'package:entrelares_core/entrelares_core.dart';
import 'package:test/test.dart';

const _fallback = 'Erro ao salvar.';
final _pt = Localization(AppLanguage.ptBr);
final _en = Localization(AppLanguage.en);

void main() {
  group('isUniqueDayConflict', () {
    test('the INSERT race signature (23505 + our constraint name)', () {
      expect(
          isUniqueDayConflict(
              '{"code":"23505","message":"duplicate key value violates unique '
              'constraint \\"care_schedules_family_schedule_date_key\\""}'),
          isTrue);
    });
    test('23505 on ANOTHER constraint is not a day conflict', () {
      expect(
          isUniqueDayConflict('{"code":"23505","message":"duplicate key value '
              'violates unique constraint \\"swap_requests_one_pending_per_date\\""}'),
          isFalse);
    });
  });

  group('isStaleDayConflict (T-33 revision guard)', () {
    test('our trigger message is the stable contract', () {
      expect(
          isStaleDayConflict('Outro responsável salvou este dia primeiro — '
              'atualize o calendário.'),
          isTrue);
    });
    test('unrelated message → false', () {
      expect(isStaleDayConflict('network unreachable'), isFalse);
    });
  });

  group('isDayConflict', () {
    test('either race counts', () {
      expect(isDayConflict('… salvou este dia primeiro …'), isTrue);
      expect(
          isDayConflict('23505 … care_schedules_family_schedule_date_key'),
          isTrue);
      expect(isDayConflict('timeout'), isFalse);
    });
  });

  group('isStaleClientBuild (T-35)', () {
    test('the reload-the-app instruction is NOT a day conflict', () {
      const raw = 'Versão do aplicativo desatualizada — Recarregue o aplicativo.';
      expect(isStaleClientBuild(raw), isTrue);
      expect(isDayConflict(raw), isFalse);
    });
  });

  group('isSessionExpired (pilot lesson 1.2)', () {
    test('42501 / permission denied maps to session expiry, not a GRANT bug', () {
      expect(
          isSessionExpired(
              'PostgrestException: permission denied for function admin_x, code: 42501'),
          isTrue);
      expect(isSessionExpired('row not found'), isFalse);
    });
  });

  group('translateSaveError', () {
    test('23505 generic → "salvou este dia primeiro"', () {
      const raw = 'Exception: {"code":"23505","message":"duplicate key value '
          'violates unique constraint \\"care_schedules_family_schedule_date_key\\""}';
      expect(
          translateSaveError(raw, _fallback, _pt),
          'Outro responsável salvou este dia primeiro — atualize o calendário '
          'e tente novamente.');
    });
    test('23505 on the pending-swap constraint gets its own message', () {
      const raw = '{"code":"23505","message":"duplicate key value violates '
          'unique constraint \\"swap_requests_one_pending_per_date\\""}';
      expect(
          translateSaveError(raw, _fallback, _pt),
          'Já existe uma solicitação pendente para este dia — o calendário '
          'foi atualizado.');
    });
    // U-13 port: the known signatures follow the reader's language.
    test('known signatures render in English for an English reader', () {
      const raw = 'Exception: {"code":"23505","message":"duplicate key value '
          'violates unique constraint \\"care_schedules_family_schedule_date_key\\""}';
      expect(translateSaveError(raw, _fallback, _en),
          'The other caregiver saved this day first — refresh the calendar '
          'and try again.');
    });
    test('trigger-raised PT-BR (accented) message passes through', () {
      const raw = '{"code":"P0001","message":"Dias passados são imutáveis."}';
      expect(translateSaveError(raw, _fallback, _pt),
          'Dias passados são imutáveis.');
      // The server writes PT-BR regardless of the reader — the pass-through
      // is deliberately language-blind (the sentence is the server's own).
      expect(translateSaveError(raw, _fallback, _en),
          'Dias passados são imutáveis.');
    });
    test('unaccented unknown message keeps the fallback', () {
      const raw = '{"code":"P0001","message":"some internal detail"}';
      expect(translateSaveError(raw, _fallback, _pt), _fallback);
    });
    test('non-JSON body keeps the fallback', () {
      expect(translateSaveError('total garbage', _fallback, _pt), _fallback);
    });
    test('malformed JSON between braces keeps the fallback', () {
      expect(translateSaveError('{not json}', _fallback, _pt), _fallback);
    });
  });

  group('sessionExpiredMessage', () {
    test('follows the reader language', () {
      expect(sessionExpiredMessage(_pt),
          'Sessão expirada — saia e entre novamente.');
      expect(sessionExpiredMessage(_en),
          'Session expired — sign out and sign in again.');
    });
  });
}
