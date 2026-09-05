#pragma warning disable ASPIRECOSMOSDB001 // RunAsPreviewEmulator is experimental.
#pragma warning disable ASPIREPROBES001 // WithHttpProbe is experimental.
#pragma warning disable ASPIRECOMPUTE002 // IComputeEnvironmentResource.GetHostAddressExpression is experimental.
#pragma warning disable AZPROVISION001 // CdnProfile.FromExisting is for evaluation purposes only.

using Aspire.Hosting.ApplicationModel;
using Aspire.Hosting.Azure;
using Azure.Core;
using Azure.Provisioning;
using Azure.Provisioning.AppContainers;
using Azure.Provisioning.Cdn;
using Azure.Provisioning.Expressions;

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
var aca = builder.AddAzureContainerAppEnvironment("aca");

// Production telemetry backend (issue #366): ServiceDefaults' OTel wiring already exports to
// the Aspire dashboard locally via OTLP; WithReference below sets APPLICATIONINSIGHTS_CONNECTION_STRING
// on api/web so Azure.Monitor.OpenTelemetry.AspNetCore additionally exports there once deployed.
// Only provisions when actually deployed (`aspire deploy`/`aspire publish`) — in Run mode the
// connection string stays unset and telemetry keeps flowing to the local dashboard as usual.
var insights = builder.AddAzureApplicationInsights("insights");

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
    .WithReference(insights)
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
    .WithReference(insights)
    .WithReference(api)
    .WithEnvironment("Authentication__Google__ClientId", googleClientId)
    .WithEnvironment("Authentication__Google__ClientSecret", googleClientSecret)
    .WaitFor(api)
    .PublishAsAzureContainerApp(ScaleToZero);

// Azure Front Door (issue #367): routes api.kuulla.us -> api and app.kuulla.us -> web through the
// existing shared Front Door profile ("azure-shared", Standard SKU, Terraform-managed, resource
// group "azure-shared") rather than provisioning a new one.
//
// This is hand-built via the low-level AddAzureInfrastructure + PublishAsExisting rather than the
// (brand-new preview) AddAzureFrontDoor integration: confirmed against a real deploy that
// AddAzureFrontDoor's own code always creates a *new* CdnProfile regardless of
// PublishAsExisting/AsExisting — unlike e.g. the App Service integration, it never checks
// resource.IsExisting() before declaring the profile. PublishAsExisting below still does its job
// of scoping this whole module's deployment to the azure-shared resource group (confirmed by that
// same deploy — the stray profile landed in the right resource group, just as a new profile
// instead of a reference to the real one); CdnProfile.FromExisting is what actually references
// the real "azure-shared" profile instead of declaring a second one.
//
// PublishAsExisting only takes effect for `aspire deploy`/`aspire publish`, so in Run mode this
// whole resource is inert, same as the ACA resources above.
var frontDoor = builder.AddAzureInfrastructure("frontdoor", infra =>
{
    var profile = CdnProfile.FromExisting("azureShared");
    profile.Name = "azure-shared";
    infra.Add(profile);

    AddOrigin(infra, profile, aca.Resource, api.Resource, api.GetEndpoint("http"), "api.kuulla.us");
    AddOrigin(infra, profile, aca.Resource, web.Resource, web.GetEndpoint("http"), "app.kuulla.us");

    static void AddOrigin(
        AzureResourceInfrastructure infra,
        CdnProfile profile,
        IComputeEnvironmentResource computeEnv,
        IResource originResource,
        EndpointReference endpointReference,
        string hostName)
    {
        var originBicepId = Infrastructure.NormalizeBicepIdentifier(originResource.Name);

        var hostExpression = computeEnv.GetHostAddressExpression(endpointReference);
        var hostParam = hostExpression.AsProvisioningParameter(infra, $"{originBicepId}_host");

        var endpoint = new FrontDoorEndpoint($"{originBicepId}Endpoint")
        {
            Parent = profile,
            Location = new AzureLocation("Global")
        };
        infra.Add(endpoint);

        var originGroup = new FrontDoorOriginGroup($"{originBicepId}OriginGroup")
        {
            Parent = profile,
            // Points at the unconditional /health endpoint both apps expose instead of the "/"
            // default, tolerant of the scale-to-zero cold-start window (#361).
            HealthProbeSettings = new HealthProbeSettings
            {
                ProbeProtocol = HealthProbeProtocol.Https,
                ProbePath = "/health"
            },
            // Required by ARM even with a single origin per group.
            LoadBalancingSettings = new LoadBalancingSettings
            {
                SampleSize = 4,
                SuccessfulSamplesRequired = 3,
                AdditionalLatencyInMilliseconds = 50
            }
        };
        infra.Add(originGroup);

        var origin = new FrontDoorOrigin($"{originBicepId}Origin")
        {
            Parent = originGroup,
            HostName = hostParam,
            OriginHostHeader = hostParam
        };
        infra.Add(origin);

        var route = new FrontDoorRoute($"{originBicepId}Route")
        {
            Parent = endpoint,
            OriginGroupId = originGroup.Id,
            PatternsToMatch = ["/*"],
            ForwardingProtocol = ForwardingProtocol.HttpsOnly,
            LinkToDefaultDomain = LinkToDefaultDomain.Enabled,
            HttpsRedirect = HttpsRedirect.Enabled
        };
        // Route must wait for origin to be created — without this, ARM deploys the route in
        // parallel and fails because the origin group has no origins yet (OriginGroupId above
        // isn't enough for ARM to infer the dependency transitively).
        route.DependsOn.Add(origin);
        infra.Add(route);

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

        infra.Add(new ProvisioningOutput($"{originBicepId}_endpointUrl", typeof(string))
        {
            Value = BicepFunction.Interpolate($"https://{endpoint.HostName}")
        });

        // Cloudflare needs this as a TXT record on the domain (e.g. _dnsauth.api.kuulla.us) before
        // Front Door will validate it — read it from the deploy output after `aspire deploy`.
        infra.Add(new ProvisioningOutput($"{originBicepId}_domainValidationToken", typeof(string))
        {
            Value = domain.ValidationProperties.ValidationToken
        });
    }
})
.PublishAsExisting("azure-shared", "azure-shared");

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
