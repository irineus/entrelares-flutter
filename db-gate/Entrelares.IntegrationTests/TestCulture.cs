using System.Globalization;
using System.Runtime.CompilerServices;

namespace Entrelares.IntegrationTests
{
    // Mirror of Program.cs: dates sent to Supabase must be ISO 8601. The test
    // host inherits the machine culture (pt-BR → "26/07/2026" in URL filters,
    // which PostgREST rejects with 22008), so force invariant before any test
    // thread starts.
    internal static class TestCulture
    {
        [ModuleInitializer]
        internal static void ForceInvariant()
        {
            CultureInfo.DefaultThreadCurrentCulture = CultureInfo.InvariantCulture;
            CultureInfo.DefaultThreadCurrentUICulture = CultureInfo.InvariantCulture;
            CultureInfo.CurrentCulture = CultureInfo.InvariantCulture;
            CultureInfo.CurrentUICulture = CultureInfo.InvariantCulture;
        }
    }
}
