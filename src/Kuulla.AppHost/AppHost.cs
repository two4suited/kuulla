#pragma warning disable ASPIRECOSMOSDB001 // RunAsPreviewEmulator is experimental.
#pragma warning disable ASPIREPROBES001 // WithHttpProbe is experimental.

using Aspire.Hosting.ApplicationModel;
using Aspire.Hosting.Azure;
using Azure.Provisioning;
using Azure.Provisioning.AppContainers;
using Azure.Provisioning.Cdn;

var builder = DistributedApplication.CreateBuilder(args);

// Scale-to-zero on the Consumption plan (issues #361, #363): min replicas 0 for api, web, and redis.
// Aspire sets Template.Scale.MinReplicas = 1 by default; overriding it here is the only way to
// get to zero since there's no dedicated builder method for it yet. No custom Rules are added —
// leaving Rules empty means ACA falls back to its default HTTP concurrent-requests scale rule,
// which is what wakes a cold instance on the first inbound request via WithExternalHttpEndpoints.
// redis has no HTTP ingress, so its scale rule falls back to ACA's default TCP-connections rule
// instead — an inbound connection from api wakes it the same way.
// CooldownPeriod is the number of seconds KEDA waits after the last active trigger before
// scaling down to MinReplicas; ACA defaults it to 300s (5 minutes), so it's raised here to keep
// containers warm for 30 minutes of inactivity instead.
// This only takes effect in publish/deploy mode; PublishAsAzureContainerApp is a no-op locally.
static void ScaleToZero(AzureResourceInfrastructure _, ContainerApp app)
{
    app.Template.Scale.MinReplicas = 0;
    app.Template.Scale.CooldownPeriod = (int)TimeSpan.FromMinutes(30).TotalSeconds;
}

// Azure Container Apps environment for `aspire deploy`/`aspire publish` (Consumption plan).
// Single compute environment, so every compute resource below deploys here without needing
// explicit .WithComputeEnvironment(...) calls.
builder.AddAzureContainerAppEnvironment("aca");

var cosmos = builder.AddAzureCosmosDB("cosmos")
    .RunAsPreviewEmulator(emulator => emulator.WithDataExplorer())
    .AddCosmosDatabase("kuulladb");

var users = cosmos.AddContainer("users", partitionKeyPath: "/id");
var shows = cosmos.AddContainer("shows", partitionKeyPath: "/id");
var episodes = cosmos.AddContainer("episodes", partitionKeyPath: "/ShowId");
var subscriptions = cosmos.AddContainer("subscriptions", partitionKeyPath: "/UserId");
var settings = cosmos.AddContainer("settings", partitionKeyPath: "/id");
var episodeStates = cosmos.AddContainer("episodestates", partitionKeyPath: "/UserId");
var playlists = cosmos.AddContainer("playlists", partitionKeyPath: "/UserId");
var deviceTokens = cosmos.AddContainer("devicetokens", partitionKeyPath: "/UserId");

var redis = builder.AddRedis("redis")
    .PublishAsAzureContainerApp(ScaleToZero);

// Google OAuth credentials for "Login with Google" (milestone #1, issues #5-#8).
// Values come from Parameters:<name> in the AppHost's user secrets locally —
// see the `dotnet user-secrets set` commands below once the GCP OAuth app exists.
var googleClientId = builder.AddParameter("google-client-id");
var googleClientSecret = builder.AddParameter("google-client-secret", secret: true);
var googleIosClientId = builder.AddParameter("google-ios-client-id");

// Front Door's ID for the shared "azure-shared" profile (issue #367) — not a secret, it's sent
// on every request Front Door forwards and is discoverable from the profile itself, but it's
// still a parameter rather than hardcoded in Program.cs so it isn't tied to this one shared
// profile if that ever changes. Empty in Run mode (local dev isn't behind Front Door), which is
// what leaves UseFrontDoorIdRestriction (Kuulla.ServiceDefaults/Extensions.cs) a no-op there.
var frontDoorId = builder.AddParameter(
    "frontdoor-id",
    value: builder.ExecutionContext.IsPublishMode ? "39174db2-771d-4851-8b26-b1e6049393fd" : "",
    secret: false);

// APNs credentials for push notifications (milestone #32, issue #216). Unlike the Google OAuth
// params above, these default to empty strings rather than being required — push notifications
// are optional infrastructure, so a `dotnet user-secrets set` for these isn't part of getting a
// local dev environment running; the API falls back to a no-op notification sender (with a
// startup warning) when any of them is unset.
var apnsKeyId = builder.AddParameter("apns-key-id", value: "", secret: false);
var apnsTeamId = builder.AddParameter("apns-team-id", value: "", secret: false);
var apnsBundleId = builder.AddParameter("apns-bundle-id", value: "", secret: false);
var apnsPrivateKey = builder.AddParameter("apns-private-key", value: "", secret: true);

// Container Apps rejects a secret resource with no value and no Key Vault reference, so an
// unset apns-private-key must not be wired up as a secret at all rather than as an empty one.
var apnsConfigured = !string.IsNullOrWhiteSpace(await apnsPrivateKey.Resource.GetValueAsync(default));

var apiBuilder = builder.AddProject<Projects.Kuulla_Api>("api")
    .WithExternalHttpEndpoints()
    // Front Door's health probe (below) targets this instead of the default "/" so a cold-started
    // replica (#361) doesn't get probed on an arbitrary route.
    .WithHttpProbe(ProbeType.Liveness, "/health")
    .WithEnvironment("FrontDoor__Id", frontDoorId)
    .WithReference(cosmos)
    .WithReference(users)
    .WithReference(shows)
    .WithReference(episodes)
    .WithReference(subscriptions)
    .WithReference(settings)
    .WithReference(episodeStates)
    .WithReference(playlists)
    .WithReference(deviceTokens)
    .WithReference(redis)
    .WithEnvironment("Google__ClientId", googleClientId)
    .WithEnvironment("Google__IosClientId", googleIosClientId);

if (apnsConfigured)
{
    apiBuilder
        .WithEnvironment("Apns__KeyId", apnsKeyId)
        .WithEnvironment("Apns__TeamId", apnsTeamId)
        .WithEnvironment("Apns__BundleId", apnsBundleId)
        .WithEnvironment("Apns__PrivateKey", apnsPrivateKey);
}

var api = apiBuilder
    .WaitFor(cosmos)
    .WaitFor(users)
    .WaitFor(shows)
    .WaitFor(episodes)
    .WaitFor(subscriptions)
    .WaitFor(settings)
    .WaitFor(episodeStates)
    .WaitFor(playlists)
    .WaitFor(deviceTokens)
    .WaitFor(redis)
    .PublishAsAzureContainerApp(ScaleToZero);

var web = builder.AddProject<Projects.Kuulla_Web>("web")
    .WithExternalHttpEndpoints()
    .WithHttpProbe(ProbeType.Liveness, "/health")
    .WithEnvironment("FrontDoor__Id", frontDoorId)
    .WithReference(api)
    .WithEnvironment("Authentication__Google__ClientId", googleClientId)
    .WithEnvironment("Authentication__Google__ClientSecret", googleClientSecret)
    .WaitFor(api)
    .PublishAsAzureContainerApp(ScaleToZero);

// Azure Front Door (issue #367): routes api.kuulla.us -> api and app.kuulla.us -> web through the
// existing shared Front Door profile (Standard SKU, Terraform-managed, resource group
// "azure-shared") rather than provisioning a new one — PublishAsExisting only takes effect for
// `aspire deploy`/`aspire publish`, so this is a no-op locally same as the ACA resources above.
// AddAzureFrontDoor is a brand-new preview API (Aspire.Hosting.Azure.FrontDoor) with a minimal
// surface today: WithOrigin gives each backend its own *.azurefd.net endpoint/origin
// group/route, and health probe path comes from the WithHttpProbe annotations above. It has no
// custom-domain API yet, so those are added by hand below via ConfigureInfrastructure.
var frontDoor = builder.AddAzureFrontDoor("frontdoor")
    .PublishAsExisting("azure-shared", "azure-shared")
    .WithOrigin(api)
    .WithOrigin(web);

frontDoor.ConfigureInfrastructure(infra =>
{
    var profile = infra.GetProvisionableResources().OfType<CdnProfile>().Single();

    AddCustomDomain(infra, profile, api.Resource.Name, "api.kuulla.us");
    AddCustomDomain(infra, profile, web.Resource.Name, "app.kuulla.us");

    static void AddCustomDomain(AzureResourceInfrastructure infra, CdnProfile profile, string originName, string hostName)
    {
        var originBicepId = Infrastructure.NormalizeBicepIdentifier(originName);
        var route = infra.GetProvisionableResources().OfType<FrontDoorRoute>()
            .Single(r => r.BicepIdentifier == $"{originBicepId}Route");

        var domain = new FrontDoorCustomDomain($"{originBicepId}Domain")
        {
            Parent = profile,
            HostName = hostName,
            // Front Door issues and renews this itself once the domain validates (TXT record
            // below) and DNS points at the route — no cert material to manage ourselves.
            TlsSettings = new FrontDoorCustomDomainHttpsContent
            {
                CertificateType = FrontDoorCertificateType.ManagedCertificate
            }
        };
        infra.Add(domain);

        route.CustomDomains.Add(new FrontDoorActivatedResourceInfo { Id = domain.Id });

        // Cloudflare needs this as a TXT record on the domain (e.g. _dnsauth.api.kuulla.us) before
        // Front Door will validate it — read it from the deploy output after `aspire deploy`.
        infra.Add(new ProvisioningOutput($"{originBicepId}_domainValidationToken", typeof(string))
        {
            Value = domain.ValidationProperties.ValidationToken
        });
    }
});

// Builds and launches the app in the iOS Simulator with the API's Aspire-resolved
// endpoint injected, so it doesn't need a manually-set KUULLA_API_BASE_URL (see #50, #51).
// macOS-only (xcodebuild/simctl aren't available elsewhere) and explicit-start
// since a full Xcode build is too slow to run on every `aspire run`/`aspire start`.
if (OperatingSystem.IsMacOS())
{
    var repoRoot = Path.GetFullPath(Path.Combine(builder.AppHostDirectory, "..", ".."));
    builder.AddExecutable("ios-simulator", Path.Combine(repoRoot, "scripts", "run-ios-simulator.sh"), repoRoot)
        .WithEnvironment("KUULLA_API_BASE_URL", api.GetEndpoint("http"))
        .WaitFor(api)
        .WithExplicitStart();
}

// Subscribes the local dev user to 5 real podcasts so a fresh `aspire run`/`aspire start`
// environment has real shows/episodes to look at instead of an empty library (issue #246).
// Non-Windows only (the script assumes bash/curl/python3, mirroring the ios-simulator resource's
// own OS gate above) and explicit-start so it never runs as part of Kuulla.AppHost.Tests, which
// boots this same AppHost — start it from the Aspire dashboard once "api" is healthy.
if (!OperatingSystem.IsWindows())
{
    var repoRoot = Path.GetFullPath(Path.Combine(builder.AppHostDirectory, "..", ".."));
    builder.AddExecutable("seed-dev-data", Path.Combine(repoRoot, "scripts", "seed-dev-data.sh"), repoRoot)
        .WithEnvironment("KUULLA_API_BASE_URL", api.GetEndpoint("http"))
        .WaitFor(api)
        .WithExplicitStart();
}

builder.Build().Run();
