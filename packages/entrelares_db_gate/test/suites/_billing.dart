import 'dart:convert';

import 'package:entrelares_db_contracts/entrelares_db_contracts.dart';
import 'package:entrelares_db_gate/entrelares_db_gate.dart';
import 'package:http/http.dart' as http;

/// Shared plumbing for the billing suites — the two rails talk to the same
/// three surfaces, and each of them has a shape worth writing down once.
///
/// **The seeds use FIXED external ids** (`sub_e2e_*`), which is what makes them
/// idempotent-by-necessity: a CI run cancelled by the concurrency group dies
/// before teardown, the orphan sweep deliberately spares anything younger than
/// 2 h, and the next run then finds the id already taken (23505). Every seed
/// deletes its own leftover first.
class Billing {
  Billing(this.fx);

  final GateFixture fx;

  /// The webhook's shared token. ABSENT is a valid state: the secret is
  /// provisioned out-of-band, so the tests that need a real webhook call arm
  /// themselves only when it exists — the same shape the deploy gives the
  /// Cloudflare credentials.
  static String? get webhookToken => TestEnv.optional('E2E_ASAAS_WEBHOOK_TOKEN');

  static String functionUrl(String name) =>
      '${TestEnv.supabaseUrl.replaceAll(RegExp(r'/+$'), '')}/functions/v1/$name';

  /// A subscription row as the checkout creates it, then moved to [status].
  Future<Subscription> seed(
    int familyId,
    String tag, {
    String status = 'pending',
    DateTime? periodEnd,
    DateTime? overdueSince,
    String? billingType,
    String? customerId,
    int priceCents = 1490,
  }) async {
    await fx.deleteSubscriptionSeed('sub_e2e_$tag');
    final inserted = Subscription.fromJson((await fx.service
            .from('subscriptions')
            .insert({
              'family_id': familyId,
              'external_subscription_id': 'sub_e2e_$tag',
              'cycle': 'monthly',
              'price_cents': priceCents,
            })
            .select())
        .single);

    return Subscription.fromJson((await fx.service
            .from('subscriptions')
            .update({
              'status': status,
              'current_period_end': periodEnd?.toIso8601String(),
              'overdue_since': overdueSince?.toIso8601String(),
              'billing_type': billingType,
              'external_customer_id': customerId,
            })
            .eq('id', inserted.id)
            .select())
        .single);
  }

  Future<Subscription> reload(int id) async => Subscription.fromJson(
      (await fx.service.from('subscriptions').select().eq('id', id)).single);

  /// The family's single subscription, read as the MEMBER sees it — which also
  /// proves the family-scoped SELECT policy on the way past.
  Future<Subscription> subscriptionOf(ThrowawayFamily fam) async =>
      Subscription.fromJson(
          (await fam.member.from('subscriptions').select()).single);

  Future<void> setPlan(int familyId, String plan) => fx.service.rpc<dynamic>(
      'set_family_plan', params: {'p_family_id': familyId, 'p_plan': plan});

  Future<String> planOf(int familyId) async => Family.fromJson(
          (await fx.service.from('families').select().eq('id', familyId)).single)
      .plan;

  Future<bool> isPremium(int familyId) async =>
      (await fx.service.rpc<dynamic>('is_premium', params: {'p_family_id': familyId}))
          .toString()
          .contains('true');

  /// F-46: the webhook folds a STILL-RUNNING trial into the paid period, and
  /// fresh families carry a 30-day trial by default. A test that models a
  /// POST-trial family must clear it, or the trial wins the max and shifts every
  /// period assertion by weeks.
  Future<void> setTrial(int familyId, DateTime? endsAtUtc) => fx.service
      .from('families')
      .update({'trial_ends_at': endsAtUtc?.toIso8601String()}).eq(
          'id', familyId);

  /// A call to the checkout function with the caller's own session, which is the
  /// shape the app uses: publishable key on `apikey`, user JWT on Authorization.
  Future<(int status, String body)> checkout(
      Map<String, dynamic> payload, String? accessToken) async {
    final response = await http.post(
      Uri.parse(functionUrl('billing-checkout')),
      headers: {
        'apikey': TestEnv.anonKey,
        'Authorization': ?_bearer(accessToken),
        'Content-Type': 'application/json',
      },
      body: jsonEncode(payload),
    );
    return (response.statusCode, response.body);
  }

  /// A gateway event, signed with the shared token the function checks.
  Future<(int status, String body)> webhook(
      Map<String, dynamic> payload, String? token) async {
    final response = await http.post(
      Uri.parse(functionUrl('billing-webhook')),
      headers: {
        'asaas-access-token': ?token,
        'Content-Type': 'application/json',
      },
      body: jsonEncode(payload),
    );
    return (response.statusCode, response.body);
  }

  /// A ledger row exactly as the webhook writes it. The table has no
  /// authenticated write path by design, so this always goes through the service
  /// client.
  Future<void> seedEvent(
    int familyId,
    String eventType, {
    String? paymentId,
    double? value,
    String? billingType,
    String? invoiceUrl,
  }) async {
    await fx.service.from('billing_events').insert({
      'event_id': 'evt_e2e_${uniqueEventSuffix()}',
      'event_type': eventType,
      'family_id': familyId,
      'payload': {
        'payment': paymentId == null
            ? null
            : {
                'id': paymentId,
                'value': value,
                'billingType': billingType,
                'invoiceUrl': invoiceUrl,
              },
      },
    });
  }

  /// `Bearer <token>`, or null when there is no session — which is how the
  /// "no credentials" cases reach the function with the header simply ABSENT
  /// rather than present and empty.
  static String? _bearer(String? accessToken) =>
      accessToken == null ? null : 'Bearer $accessToken';

  static int _eventCounter = 0;

  /// GUID-suffixed ids need no delete-first (unlike the `sub_e2e_*` seeds), but
  /// they DO need to be unique across a run — a counter plus the run id is
  /// enough and keeps the value readable in the table.
  String uniqueEventSuffix() => '${fx.runId}-${_eventCounter++}';
}
