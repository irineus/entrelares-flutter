import 'dart:convert';

import 'package:entrelares_db_contracts/entrelares_db_contracts.dart';
import 'package:entrelares_db_gate/entrelares_db_gate.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

/// T-49 — the suites drive the REAL flows, so every run used to hand the
/// fixture's throwaway addresses to Resend for real: ~86 e-mails a day, all from
/// CI, against the allowance PRODUCTION shares (one Resend account, one domain —
/// including the GoTrue SMTP that sends sign-up confirmations). The functions now
/// suppress the outbound call for `@resend.dev` recipients.
///
/// This is the red gate for that. Without it the guard is invisible when it
/// regresses: nothing in the app reads the functions' response, and no test ever
/// asserted delivery — the quota would simply start bleeding again, and the first
/// sign would be a Resend warning days later. The casualty of a 429 in production
/// is not a red test: it is a real user who cannot confirm a sign-up or reset a
/// password, with nothing surfacing the failure.
///
/// It asserts the DISTINCTION, not merely "nothing was sent": `suppressed` must
/// COUNT the message and `failed` must stay zero, which is what proves the send
/// was skipped on purpose rather than broken.
///
/// Port of `db-gate/Entrelares.IntegrationTests/TestRecipientSuppressionTests.cs`.
void testRecipientSuppressionTests(GateFixture fx) {
  group('TestRecipientSuppressionTests', () {
    test('a swap e-mail to a test recipient is suppressed, not failed',
        () async {
      // The app's own path: a signed-in user dispatching a swap e-mail.
      final request = SwapRequest.fromJson((await fx.member
              .from('swap_requests')
              .insert({
                'schedule_date': isoDate(fx.nextFutureDate()),
                'requesting_profile_id': fx.memberProfile.id,
                'target_profile_id': fx.founderProfile.id,
                'previous_actual_parent_id': null,
                'proposed_actual_parent_id': fx.memberProfile.id,
                'status': 'pending',
              })
              .select())
          .single);

      // S-16: the app calls with the publishable key on `apikey` and the user's
      // session on Authorization — the same shape the function's own check
      // expects.
      final accessToken = fx.member.auth.currentSession?.accessToken;
      expect(accessToken, isNotNull,
          reason: 'the member client has no session — '
              'the fixture sign-in did not complete');

      final response = await http.post(
        Uri.parse('${TestEnv.supabaseUrl.replaceAll(RegExp(r'/+$'), '')}'
            '/functions/v1/send-swap-email'),
        headers: {
          'apikey': TestEnv.anonKey,
          'Authorization': 'Bearer $accessToken',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'swapRequestId': request.id,
          'emailType': 'swap_requested',
          'environmentPrefix': '[T-49] ',
        }),
      );

      expect(response.statusCode, 200,
          reason: 'send-swap-email answered ${response.statusCode} '
              '(expected 200). Body: ${response.body}');

      final body = jsonDecode(response.body) as Map<String, dynamic>;

      expect(body['suppressed'], isNotNull,
          reason: "the response carries no 'suppressed' count — the T-49 guard "
              'is gone and the fixture e-mails are reaching Resend again. '
              'Body: ${response.body}');
      expect(body['suppressed'], greaterThanOrEqualTo(1),
          reason: 'expected at least one suppressed test recipient. '
              'Body: ${response.body}');
      expect(body['sent'], 0);
      expect(body['failed'], 0);
    });
  });
}
