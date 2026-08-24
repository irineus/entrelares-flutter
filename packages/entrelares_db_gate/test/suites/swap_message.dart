import 'package:entrelares_db_contracts/entrelares_db_contracts.dart';
import 'package:entrelares_db_gate/entrelares_db_gate.dart';
import 'package:supabase/supabase.dart';
import 'package:test/test.dart';

/// F-44 — the requester message (set at creation) and the approver note (set on
/// approval) persist on `swap_requests` and are readable by the OTHER party
/// through the family-scoped RLS, exactly as the app's panels need them.
///
/// Requests are written through the AUTHENTICATED user clients, so the policies
/// the real workflow hits are the ones under test.
///
/// Port of `db-gate/Entrelares.IntegrationTests/SwapMessageTests.cs`.
void swapMessageTests(GateFixture fx) {
  Future<SwapRequest> openRequest(DateTime date, String message) async =>
      SwapRequest.fromJson((await fx.member
              .from('swap_requests')
              .insert({
                'schedule_date': isoDate(date),
                'requesting_profile_id': fx.memberProfile.id,
                'target_profile_id': fx.founderProfile.id,
                'previous_actual_parent_id': null,
                'proposed_actual_parent_id': fx.memberProfile.id,
                'status': 'pending',
                'request_message': message,
              })
              .select())
          .single);

  Future<SwapRequest> readAs(SupabaseClient client, int id) async =>
      SwapRequest.fromJson(
          (await client.from('swap_requests').select().eq('id', id)).single);

  group('SwapMessageTests', () {
    test("the requester's message persists and reaches the target", () async {
      final request = await openRequest(
          fx.nextFutureDate(), 'Tenho consulta médica nesse dia');

      final seenByTarget = await readAs(fx.founder, request.id);

      expect(seenByTarget.requestMessage, 'Tenho consulta médica nesse dia');
      expect(seenByTarget.approvalNote, isNull);
    });

    test("the approver's note persists on approval and reaches the requester",
        () async {
      final request =
          await openRequest(fx.nextFutureDate(), 'Viagem de trabalho');

      await fx.founder.from('swap_requests').update({
        'status': 'approved',
        'approval_note': 'Combinado, busco às 18h',
        'resolved_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', request.id);

      final seenByRequester = await readAs(fx.member, request.id);

      expect(seenByRequester.status, 'approved');
      expect(seenByRequester.approvalNote, 'Combinado, busco às 18h');
      // The creation message survives resolution untouched.
      expect(seenByRequester.requestMessage, 'Viagem de trabalho');
    });
  });
}
