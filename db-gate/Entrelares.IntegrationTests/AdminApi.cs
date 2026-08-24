using System.Net;
using System.Net.Http.Json;
using System.Text.Json;

namespace Entrelares.IntegrationTests
{
    // Thin GoTrue Admin API wrapper (service_role): creates PRE-CONFIRMED test
    // users — the insert into auth.users fires the real handle_new_user trigger
    // (founder/invitee onboarding) without depending on confirmation e-mails —
    // and removes them at teardown (profiles.user_id has no cascade, so users
    // are deleted AFTER purge_e2e_family removed the public-schema rows).
    public sealed class AdminApi : IDisposable
    {
        private readonly HttpClient _http;

        public AdminApi()
        {
            _http = new HttpClient { BaseAddress = new Uri(TestEnv.SupabaseUrl) };
            // S-16: header shape depends on the key format — see TestEnv.ApplyKeyHeaders.
            _http.DefaultRequestHeaders.Add("apikey", TestEnv.ServiceRoleKey);
            if (!TestEnv.IsNewKeyFormat(TestEnv.ServiceRoleKey))
                _http.DefaultRequestHeaders.Authorization = new("Bearer", TestEnv.ServiceRoleKey);
        }

        public async Task<Guid> CreateConfirmedUserAsync(string email, string password, object metadata)
        {
            var response = await _http.PostAsJsonAsync("/auth/v1/admin/users", new
            {
                email,
                password,
                email_confirm = true,
                user_metadata = metadata
            });
            var body = await response.Content.ReadAsStringAsync();
            if (!response.IsSuccessStatusCode)
                throw new InvalidOperationException($"Admin create user '{email}' failed ({(int)response.StatusCode}): {body}");

            using var doc = JsonDocument.Parse(body);
            return doc.RootElement.GetProperty("id").GetGuid();
        }

        /// <summary>F-16 tests: changes a user's e-mail as GoTrue itself would
        /// after the confirmation link — exercising the profiles.email sync
        /// trigger without a mailbox round-trip.</summary>
        public async Task UpdateUserEmailAsync(Guid userId, string newEmail)
        {
            var response = await _http.PutAsJsonAsync($"/auth/v1/admin/users/{userId}", new
            {
                email = newEmail,
                email_confirm = true
            });
            if (!response.IsSuccessStatusCode)
                throw new InvalidOperationException(
                    $"Admin update e-mail for {userId} failed ({(int)response.StatusCode}): {await response.Content.ReadAsStringAsync()}");
        }

        /// <summary>Idempotent: a user already removed (404) is not an error.</summary>
        public async Task DeleteUserAsync(Guid userId)
        {
            var response = await _http.DeleteAsync($"/auth/v1/admin/users/{userId}");
            if (!response.IsSuccessStatusCode && response.StatusCode != HttpStatusCode.NotFound)
                throw new InvalidOperationException($"Admin delete user {userId} failed ({(int)response.StatusCode}).");
        }

        public void Dispose() => _http.Dispose();
    }
}
