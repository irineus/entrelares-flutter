/// U-13 (T-53 lote 1 port) — the renderer that makes notifications
/// localizable. Ported from `entrelares-app`
/// `Entrelares.Tests/NotificationRendererTests.cs`.
///
/// These tests pin the three properties that make it safe: the reader's
/// language wins, a row that cannot be rebuilt still says something true, and
/// user data is never translated. The PT-BR table asserts BYTE-FOR-BYTE the
/// sentence the SQL trigger stores — wiring the renderer in must not make a
/// Portuguese reader's history appear to change retroactively.
library;

import 'package:entrelares_core/entrelares_core.dart';
import 'package:test/test.dart';

void main() {
  final ptBr = Localization(AppLanguage.ptBr);
  final en = Localization(AppLanguage.en);

  const storedMessage =
      'A solicitação do dia 04/08 foi aprovada automaticamente após 48h sem resposta.';
  const storedTitle = '[DEV] ✅ Solicitação aprovada automaticamente';
  const sentinel = '«stored»';

  group('the reader language wins', () {
    test('auto_approved renders in the reader language', () {
      const json = '{"date":"04/08","role":"requester"}';
      expect(
          NotificationRenderer.message(
              'auto_approved', json, storedMessage, ptBr),
          'A solicitação do dia 04/08 foi aprovada automaticamente após 48h sem resposta.');
      expect(
          NotificationRenderer.message(
              'auto_approved', json, storedMessage, en),
          'The request for 04/08 was approved automatically after 48h with no reply.');
    });

    // Same type, two different sentences — without the role discriminator
    // each reader would get the other's copy, which is simply false.
    test('auto_approved tells requester and approver apart', () {
      final requester = NotificationRenderer.message('auto_approved',
          '{"date":"04/08","role":"requester"}', storedMessage, en);
      final approver = NotificationRenderer.message('auto_approved',
          '{"date":"04/08","role":"approver"}', storedMessage, en);
      expect(requester, isNot(approver));
      expect(approver, contains('You did not reply'));
      expect(requester, isNot(contains('You did not reply')));
    });

    test('auto_approved without role uses the neutral copy', () {
      final text = NotificationRenderer.message(
          'auto_approved', '{"date":"04/08"}', storedMessage, en);
      expect(text, isNot(contains('You did not reply')));
    });

    test('auto_reminder renders in both languages', () {
      const json = '{"date":"12/09"}';
      expect(NotificationRenderer.message('auto_reminder', json, 'x', ptBr),
          contains('12/09'));
      expect(NotificationRenderer.message('auto_reminder', json, 'x', en),
          contains('will be approved automatically'));
    });

    // The family fan-out puts the SAME two values in a different order per
    // language — the reason placeholders are numbered.
    test('family info substitutes name and date in each language own order',
        () {
      const json = '{"date":"04/08","kind":"auto_revert","name":"Ana"}';
      final pt =
          NotificationRenderer.message('swap_family_info', json, 'x', ptBr);
      final enText =
          NotificationRenderer.message('swap_family_info', json, 'x', en);
      expect(pt, allOf(contains('Ana'), contains('04/08')));
      expect(enText, allOf(contains('Ana'), contains('04/08')));
      expect(pt, isNot(enText));
    });

    test('family info tells swap from revert', () {
      final swap = NotificationRenderer.message('swap_family_info',
          '{"date":"04/08","kind":"auto_swap","name":"Ana"}', 'x', en);
      final revert = NotificationRenderer.message('swap_family_info',
          '{"date":"04/08","kind":"auto_revert","name":"Ana"}', 'x', en);
      expect(swap, isNot(revert));
      expect(revert, contains('reverted'));
    });

    // THE BOUNDARY: a caregiver's name is user data, substituted as plain
    // text in every language — same rule as the F-41 custom roles.
    test('family info never translates the name', () {
      for (final l in [ptBr, en]) {
        final text = NotificationRenderer.message('swap_family_info',
            '{"date":"04/08","kind":"auto_swap","name":"Vovó Zezé"}', 'x', l);
        expect(text, contains('Vovó Zezé'));
      }
    });
  });

  group('falling back must always say something TRUE', () {
    for (final json in [null, '', '   ']) {
      test('legacy row without params ("$json") keeps the stored sentence',
          () {
        expect(
            NotificationRenderer.message(
                'auto_approved', json, storedMessage, en),
            storedMessage);
        expect(
            NotificationRenderer.title('auto_approved', json, storedTitle, en),
            storedTitle);
      });
    }

    test('unknown type keeps the stored sentence', () {
      expect(
          NotificationRenderer.message(
              'some_future_type', '{"date":"04/08"}', storedMessage, en),
          storedMessage);
    });

    for (final json in ['{not json', '[1,2,3]', '"just a string"']) {
      test('malformed params ($json) keep the stored sentence', () {
        expect(
            NotificationRenderer.message(
                'auto_approved', json, storedMessage, en),
            storedMessage);
      });
    }

    test('params without the required field keep the stored sentence', () {
      expect(
          NotificationRenderer.message(
              'auto_approved', '{"role":"requester"}', storedMessage, en),
          storedMessage);
    });

    // A JSON null is treated as absent, so the caller's own default applies
    // instead of the word "null".
    test('null name in params falls back to the generic caregiver', () {
      final text = NotificationRenderer.message('swap_family_info',
          '{"date":"04/08","kind":"auto_swap","name":null}', 'x', en);
      expect(text.toLowerCase(), isNot(contains('null')));
      expect(text, contains('Another caregiver'));
    });

    // A missing name must never produce a capital mid-sentence or a
    // lowercase at the start — one key per surface form.
    test('name fallbacks match the surface form of each sentence', () {
      expect(
          NotificationRenderer.message('swap_family_info',
              '{"date":"04/08","kind":"auto_swap"}', 'x', ptBr),
          startsWith('Outro responsável'));
      expect(
          NotificationRenderer.message(
              'swap_rejected', '{"date":"04/08/2026"}', 'x', ptBr),
          startsWith('O outro responsável'));
      expect(
          NotificationRenderer.message('swap_approved_self',
              '{"date":"04/08/2026","proposed":"requester"}', 'x', ptBr),
          contains('que o outro responsável ficará'));
      expect(
          NotificationRenderer.message('swap_family_info',
              '{"date":"04/08/2026","kind":"revert"}', 'x', ptBr),
          contains('o responsável planejado volta'));
    });
  });

  group('titles', () {
    // The stored title carries the deploy prefix ("[DEV] "), a deploy-time
    // marker the rendered title deliberately drops.
    test('rendered title drops the environment prefix', () {
      final title = NotificationRenderer.title(
          'auto_approved', '{"date":"04/08"}', storedTitle, ptBr);
      expect(title, isNot(contains('[DEV]')));
      expect(title, '✅ Solicitação aprovada automaticamente');
    });

    test('rendered title follows the reader language', () {
      expect(
          NotificationRenderer.title(
              'auto_approved', '{"date":"04/08"}', storedTitle, en),
          '✅ Request approved automatically');
    });

    // The urgency tag is content, travels in params, and is translated —
    // dropping it would leave the English reader with less information.
    for (final (tag, pt, enTitle) in [
      ('urgent', '⚠️ URGENTE: Nova solicitação de troca',
          '⚠️ URGENT: New swap request'),
      ('overdue', '⏰ ATRASADO: Nova solicitação de troca',
          '⏰ OVERDUE: New swap request'),
    ]) {
      test('urgency tag "$tag" is rendered and translated', () {
        final json = '{"date":"04/08/2026","name":"Ana","tag":"$tag"}';
        expect(NotificationRenderer.title('swap_requested', json, 'stored', ptBr),
            pt);
        expect(NotificationRenderer.title('swap_requested', json, 'stored', en),
            enTitle);
      });
    }

    test('title without tag has no prefix', () {
      expect(
          NotificationRenderer.title('swap_requested',
              '{"date":"04/08/2026","name":"Ana"}', 'stored', ptBr),
          'Nova solicitação de troca');
    });
  });

  // ── PT-BR renders EXACTLY what the writer stored ──
  //
  // Wiring the renderer in changes what a PORTUGUESE reader sees too: rows
  // with params stop showing the stored sentence and start showing the
  // catalog's. If the two differ by so much as a comma, a notification the
  // user already read appears to have changed retroactively. Each case
  // carries the payload the writer emits and the sentence that same writer
  // stored, verbatim. It doubles as the COVERAGE gate: a forgotten branch
  // falls back to the sentinel and fails loudly.
  const ptTable = <(String, String, String)>[
    // written by SwapRequestService
    ('swap_sent', '{"date":"04/08/2026","name":"Ana"}',
        'Você solicitou uma troca de guarda para o dia 04/08/2026. Aguardando resposta de Ana.'),
    ('swap_requested',
        '{"date":"04/08/2026","name":"Bruno","proposed":"target"}',
        'Bruno solicitou que você fique responsável pela criança no dia 04/08/2026.'),
    ('swap_requested',
        '{"date":"04/08/2026","name":"Bruno","proposed":"requester","msg":"Preciso viajar"}',
        'Bruno solicitou ficar responsável pela criança no dia 04/08/2026 no seu lugar. Mensagem: Preciso viajar'),
    ('swap_approved',
        '{"date":"04/08/2026","name":"Ana","proposed":"target"}',
        'Ana aceitou ficar com a criança no dia 04/08/2026.'),
    ('swap_approved',
        '{"date":"04/08/2026","name":"Ana","proposed":"requester","msg":"Combinado"}',
        'Ana aceitou que você fique com a criança no dia 04/08/2026. Mensagem: Combinado'),
    ('swap_approved_self',
        '{"date":"04/08/2026","name":"Ana","proposed":"target"}',
        'Você confirmou que ficará com a criança no dia 04/08/2026.'),
    ('swap_approved_self',
        '{"date":"04/08/2026","name":"Ana","proposed":"requester"}',
        'Você confirmou que Ana ficará com a criança no dia 04/08/2026.'),
    ('swap_rejected',
        '{"date":"04/08/2026","name":"Ana","msg":"Não vai dar"}',
        'Ana recusou a troca de guarda para o dia 04/08/2026. Mensagem: Não vai dar'),
    ('swap_cancelled', '{"kind":"by_requester","date":"04/08/2026"}',
        'A solicitação de troca para o dia 04/08/2026 foi cancelada pelo solicitante.'),
    ('revert_sent', '{"date":"04/08/2026","name":"Ana"}',
        'Você solicitou reverter a troca de guarda do dia 04/08/2026. Aguardando confirmação de Ana.'),
    ('revert_requested', '{"date":"04/08/2026","name":"Ana"}',
        'Ana quer reverter a troca de guarda do dia 04/08/2026. Você precisa confirmar.'),
    ('revert_approved', '{"date":"04/08/2026","name":"Ana"}',
        'Ana confirmou a reversão da troca do dia 04/08/2026. O calendário voltou ao normal.'),
    ('revert_approved_self', '{"date":"04/08/2026"}',
        'Você confirmou a reversão da troca do dia 04/08/2026.'),
    // The one text where the free message lands MID-sentence — the reason the
    // suffix is a catalog placeholder instead of something the code appends.
    ('revert_rejected',
        '{"date":"04/08/2026","name":"Ana","msg":"Prefiro manter"}',
        'Ana recusou reverter a troca do dia 04/08/2026. Mensagem: Prefiro manter A troca permanece ativa.'),
    ('revert_cancelled', '{"date":"04/08/2026"}',
        'O pedido de reversão da troca do dia 04/08/2026 foi cancelado.'),
    ('swap_family_info',
        '{"kind":"swap","date":"04/08/2026","name":"Ana","requester":"Bruno","approver":"Carla"}',
        'Ana ficará com a criança no dia 04/08/2026 (troca solicitada por Bruno e aprovada por Carla).'),
    ('swap_family_info',
        '{"kind":"revert","date":"04/08/2026","name":"Ana"}',
        'A troca do dia 04/08/2026 foi revertida — Ana volta a ficar com a criança.'),
    // written by the DB triggers
    ('swap_family_info',
        '{"date":"04/08","kind":"auto_swap","name":"Ana"}',
        'Ana ficará com a criança no dia 04/08 (troca aprovada automaticamente após 48h sem resposta).'),
    ('swap_family_info',
        '{"date":"04/08","kind":"auto_revert","name":"Ana"}',
        'A troca do dia 04/08 foi revertida automaticamente — Ana volta a ficar com a criança.'),
    ('member_joined', '{"name":"Ana"}',
        'Ana juntou-se à família. Confira o calendário para incluí-lo no planejamento.'),
    ('member_returned', '{"name":"Ana"}',
        'Ana cancelou a saída e voltou à família.'),
    ('swap_cancelled',
        '{"kind":"member_left","name":"Ana","date":"04/08/2026"}',
        'Ana saiu da família e a solicitação de troca de 04/08/2026 foi cancelada.'),
    ('account_deletion', '{"kind":"self"}',
        'Sua saída da família foi solicitada. Você tem 30 dias para cancelar; após esse prazo a conta será apagada.'),
    ('account_deletion', '{"kind":"self_last"}',
        'Como você é o único responsável, sua saída removerá a família e todos os dados após 30 dias. Você pode cancelar nesse período.'),
    ('account_deletion', '{"kind":"other_left","name":"Ana"}',
        'Ana saiu da família. Os dias futuros dessa pessoa foram liberados — verifique o calendário e reatribua o que for necessário.'),
    ('family_deletion', '{"kind":"requested_self","date":"05/09/2026"}',
        'Você solicitou a exclusão da família. Se ninguém recusar até 05/09/2026, todos os dados (calendário, histórico e contas) serão apagados definitivamente. Você pode retirar a solicitação a qualquer momento.'),
    ('family_deletion',
        '{"kind":"requested_other","name":"Ana","date":"05/09/2026"}',
        'Ana solicitou a exclusão da família. Se ninguém recusar até 05/09/2026, TODOS os dados (calendário, histórico e contas de todos) serão apagados definitivamente. Você pode recusar em Perfil > Exclusão da família — qualquer recusa cancela a exclusão.'),
    ('family_deletion', '{"kind":"agreed","name":"Ana"}',
        'Ana concordou com a exclusão da família.'),
    ('family_deletion', '{"kind":"agreement_undone","name":"Ana"}',
        'Ana desfez a concordância com a exclusão da família (voltou a aguardar).'),
    ('family_deletion', '{"kind":"refused","name":"Ana"}',
        'Ana recusou a exclusão da família. A solicitação foi encerrada e a família continua.'),
    ('family_deletion', '{"kind":"withdrawn","name":"Ana"}',
        'Ana retirou a solicitação de exclusão da família. A família continua normalmente.'),
    ('family_deletion', '{"kind":"reminder","date":"05/09/2026"}',
        'A família será excluída definitivamente em 05/09/2026. Você ainda pode recusar em Perfil > Exclusão da família, ou exportar seus dados antes.'),
    ('email_cap_reached', '{"tier":"premium"}',
        'Sua família atingiu o limite de e-mails deste mês. As notificações aqui no app seguem normais.'),
    ('email_cap_reached', '{"tier":"free"}',
        'Sua família atingiu o limite de e-mails deste mês no plano gratuito. As notificações aqui no app seguem normais — ative o Premium para um limite bem maior.'),
    ('email_cap_last', '{"tier":"free"}',
        'Este é o último e-mail do mês no plano gratuito. As notificações aqui no app seguem normais — ative o Premium para um limite bem maior.'),
    ('email_cap_80', '{"tier":"free"}',
        'Sua família já usou 80% dos e-mails deste mês (plano gratuito). As notificações aqui no app seguem sem limite — ative o Premium para um limite bem maior.'),
    ('billing', '{"kind":"grace_warning","date":"12/08/2026"}',
        'Não conseguimos confirmar o pagamento da assinatura. Se a cobrança não for regularizada até 12/08/2026, a família voltará ao Plano Gratuito. Nenhum dado é apagado — os recursos Premium apenas ficam indisponíveis.'),
  ];

  group('PT-BR renders EXACTLY what the writer stored', () {
    for (final (type, json, stored) in ptTable) {
      test('$type $json', () {
        expect(NotificationRenderer.message(type, json, sentinel, ptBr),
            stored);
      });
    }
  });

  group('English rendering is neither the fallback nor Portuguese', () {
    // The English side of the same table: every payload must produce a real
    // English sentence, never the stored Portuguese. Asserting "not the
    // sentinel and not Portuguese" is the honest check — pinning the English
    // wording word-for-word would just duplicate the catalog.
    const enTable = <(String, String)>[
      ('swap_sent', '{"date":"04/08/2026","name":"Ana"}'),
      ('swap_requested',
          '{"date":"04/08/2026","name":"Bruno","proposed":"target"}'),
      ('swap_approved',
          '{"date":"04/08/2026","name":"Ana","proposed":"requester"}'),
      ('swap_approved_self', '{"date":"04/08/2026","proposed":"target"}'),
      ('swap_rejected', '{"date":"04/08/2026","name":"Ana"}'),
      ('swap_cancelled', '{"kind":"by_requester","date":"04/08/2026"}'),
      ('swap_cancelled',
          '{"kind":"member_left","name":"Ana","date":"04/08/2026"}'),
      ('revert_sent', '{"date":"04/08/2026","name":"Ana"}'),
      ('revert_requested', '{"date":"04/08/2026","name":"Ana"}'),
      ('revert_approved', '{"date":"04/08/2026","name":"Ana"}'),
      ('revert_approved_self', '{"date":"04/08/2026"}'),
      ('revert_rejected', '{"date":"04/08/2026","name":"Ana"}'),
      ('revert_cancelled', '{"date":"04/08/2026"}'),
      ('swap_family_info',
          '{"kind":"swap","date":"04/08/2026","name":"Ana","requester":"Bruno","approver":"Carla"}'),
      ('swap_family_info', '{"kind":"revert","date":"04/08/2026","name":"Ana"}'),
      ('member_joined', '{"name":"Ana"}'),
      ('member_returned', '{"name":"Ana"}'),
      ('account_deletion', '{"kind":"self"}'),
      ('account_deletion', '{"kind":"self_last"}'),
      ('account_deletion', '{"kind":"other_left","name":"Ana"}'),
      ('family_deletion', '{"kind":"requested_self","date":"05/09/2026"}'),
      ('family_deletion',
          '{"kind":"requested_other","name":"Ana","date":"05/09/2026"}'),
      ('family_deletion', '{"kind":"agreed","name":"Ana"}'),
      ('family_deletion', '{"kind":"agreement_undone","name":"Ana"}'),
      ('family_deletion', '{"kind":"refused","name":"Ana"}'),
      ('family_deletion', '{"kind":"withdrawn","name":"Ana"}'),
      ('family_deletion', '{"kind":"reminder","date":"05/09/2026"}'),
      ('email_cap_reached', '{"tier":"premium"}'),
      ('email_cap_reached', '{"tier":"free"}'),
      ('email_cap_last', '{}'),
      ('email_cap_80', '{}'),
      ('billing', '{"kind":"grace_warning","date":"12/08/2026"}'),
    ];
    for (final (type, json) in enTable) {
      test('$type $json', () {
        final message = NotificationRenderer.message(type, json, sentinel, en);
        final title = NotificationRenderer.title(type, json, sentinel, en);
        expect(message, isNot(sentinel));
        expect(title, isNot(sentinel));
        // Portuguese leaves fingerprints an English sentence never carries.
        for (final giveaway in [
          'você', 'Você', 'família', 'criança', 'solicitação', 'não '
        ]) {
          expect(message, isNot(contains(giveaway)));
        }
      });
    }
  });

  group('discriminators: one type, several readers, several truths', () {
    const pairs = <(String, String, String)>[
      ('swap_cancelled', '{"kind":"by_requester","date":"04/08/2026"}',
          '{"kind":"member_left","name":"Ana","date":"04/08/2026"}'),
      ('swap_requested',
          '{"date":"04/08/2026","name":"Ana","proposed":"target"}',
          '{"date":"04/08/2026","name":"Ana","proposed":"requester"}'),
      ('swap_approved',
          '{"date":"04/08/2026","name":"Ana","proposed":"target"}',
          '{"date":"04/08/2026","name":"Ana","proposed":"requester"}'),
      ('swap_approved_self',
          '{"date":"04/08/2026","name":"Ana","proposed":"target"}',
          '{"date":"04/08/2026","name":"Ana","proposed":"requester"}'),
      ('account_deletion', '{"kind":"self"}', '{"kind":"self_last"}'),
      ('family_deletion', '{"kind":"agreed","name":"Ana"}',
          '{"kind":"agreement_undone","name":"Ana"}'),
      ('family_deletion', '{"kind":"refused","name":"Ana"}',
          '{"kind":"withdrawn","name":"Ana"}'),
      ('email_cap_reached', '{"tier":"premium"}', '{"tier":"free"}'),
      ('swap_family_info',
          '{"kind":"swap","date":"04/08","name":"Ana","requester":"B","approver":"C"}',
          '{"kind":"revert","date":"04/08","name":"Ana"}'),
    ];
    for (final (type, a, b) in pairs) {
      test('$type gives each reader their own sentence', () {
        for (final l in [ptBr, en]) {
          expect(NotificationRenderer.message(type, a, sentinel, l),
              isNot(NotificationRenderer.message(type, b, sentinel, l)));
        }
      });
    }

    // An unknown discriminator is a FUTURE writer's shape: picking one of
    // today's wordings for it would state something false.
    const unknown = <(String, String)>[
      ('swap_cancelled', '{"kind":"something_new","date":"04/08/2026"}'),
      ('account_deletion', '{"kind":"something_new"}'),
      ('family_deletion', '{"kind":"something_new","name":"Ana"}'),
      ('email_cap_reached', '{"tier":"enterprise"}'),
      ('billing', '{"kind":"something_new","date":"12/08/2026"}'),
    ];
    for (final (type, json) in unknown) {
      test('$type with unknown discriminator keeps the stored sentence', () {
        expect(NotificationRenderer.message(type, json, sentinel, en), sentinel);
        expect(NotificationRenderer.title(type, json, sentinel, en), sentinel);
      });
    }
  });

  group('free text', () {
    // A blank message must not render a dangling "Mensagem:" label.
    for (final json in [
      '{"date":"04/08/2026","name":"Ana","proposed":"target"}',
      '{"date":"04/08/2026","name":"Ana","proposed":"target","msg":""}',
      '{"date":"04/08/2026","name":"Ana","proposed":"target","msg":"   "}',
    ]) {
      test('blank free text renders no message label ($json)', () {
        expect(
            NotificationRenderer.message('swap_requested', json, sentinel, ptBr),
            isNot(contains('Mensagem')));
        expect(
            NotificationRenderer.message('swap_requested', json, sentinel, en),
            isNot(contains('Message')));
      });
    }
  });

  group('U-24: the date is data too', () {
    // Every non-ISO date in the tables above is the legacy regression — a
    // non-ISO string returns verbatim. These pin the ISO half.
    test('ISO date in params renders in the reader language', () {
      const json = '{"date":"2026-08-05","name":"Ana","proposed":"target"}';
      expect(
          NotificationRenderer.message('swap_requested', json, sentinel, ptBr),
          contains('05/08/2026'));
      expect(NotificationRenderer.message('swap_requested', json, sentinel, en),
          contains('05 Aug 2026'));
    });

    // An English reader must never be shown `05/08` — the exact string they
    // would read as May 8th, and the reason U-24 exists at all.
    test('English reader never sees the Brazilian numeric date', () {
      const json = '{"date":"2026-08-05"}';
      expect(NotificationRenderer.message('auto_reminder', json, sentinel, en),
          isNot(contains('05/08')));
    });

    test('legacy PT-BR date in params is not reinterpreted', () {
      const json = '{"date":"04/08"}';
      expect(NotificationRenderer.message('auto_reminder', json, sentinel, ptBr),
          contains('04/08'));
      expect(NotificationRenderer.message('auto_reminder', json, sentinel, en),
          contains('04/08'));
    });
  });
}
