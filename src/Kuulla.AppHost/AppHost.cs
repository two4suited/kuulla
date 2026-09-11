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
using Azure.Provisioning.CosmosDB;
using Azure.Provisioning.Expressions;

var builder = DistributedApplication.CreateBuilder(args);

// Scale-to-zero on the Consumption plan (issues #361, #363): min replicas 0 for api and web.
// Aspire sets Template.Scale.MinReplicas = 1 by default; overriding it here is the only way to
// get to zero since there's no dedicated builder method for it yet. No custom Rules are added —
// leaving Rules empty means ACA falls back to its default HTTP concurrent-requests scale rule,
// which is what wakes a cold instance on the first inbound request via WithExternalHttpEndpoints.
// CooldownPeriod is the number of seconds KEDA waits after the last active trigger before
// scaling down to MinReplicas; ACA defaults it to 300s (5 minutes), so it's lowered here to
// scale api/web back to zero after 30 seconds of inactivity. KEDA's polling interval (~30s)
// still applies on top, so expect the actual scale-down a little after that.
// This only takes effect in publish/deploy mode; PublishAsAzureContainerApp is a no-op locally.
static void ScaleToZero(AzureResourceInfrastructure _, ContainerApp app)
{
    app.Template.Scale.MinReplicas = 0;
    app.Template.Scale.CooldownPeriod = 30;
}

// Azure Container Apps environment for `aspire deploy`/`aspire publish` (Consumption plan).
// Single compute environment, so every compute resource below deploys here without needing
// explicit .WithComputeEnvironment(...) calls.
var aca = builder.AddAzureContainerAppEnvironment("aca");

// Purge old CI-built image tags so the auto-provisioned ACR (Basic tier, 10 GB) doesn't grow into
// a storage-overage charge as releases accumulate — currently at ~9% of the limit, but each tagged
// release (api/web/feed-poller) adds a new image. Runs weekly (Sunday 03:00 UTC, low-traffic);
// keeps the 10 most recent tags per repo and only purges beyond that among images older than 30
// days, so a rollback to a recent release tag always has something to roll back to. Publish-mode
// only: the ACR task itself is a deployed Azure resource, nothing to do locally.
if (builder.ExecutionContext.IsPublishMode)
{
    aca.GetAzureContainerRegistry()
        .WithPurgeTask("0 3 * * 0", keep: 10, ago: TimeSpan.FromDays(30));
}

// Production telemetry backend (issue #366): ServiceDefaults' OTel wiring already exports to
// the Aspire dashboard locally via OTLP; WithReference below sets APPLICATIONINSIGHTS_CONNECTION_STRING
// on api/web so Azure.Monitor.OpenTelemetry.AspNetCore additionally exports there once deployed.
// Publish-mode only: in Run mode the connection string stays unset and telemetry keeps flowing
// to the local dashboard as usual. It's also skipped entirely (rather than added-but-unresolved)
// so the AppHost integration tests, which boot this model via DistributedApplicationTestingBuilder
// with no Azure provisioner, don't fail "api"/"web" startup trying to resolve the bicep output
// for a resource that can't be provisioned locally.
var insights = builder.ExecutionContext.IsPublishMode
    ? builder.AddAzureApplicationInsights("insights")
    : null;

var cosmosAccount = builder.AddAzureCosmosDB("cosmos")
    .RunAsPreviewEmulator(emulator => emulator
        .WithDataExplorer()
        // Persist the emulator's data across `aspire run` restarts so a local dev environment
        // keeps its seeded shows/episodes/playback state instead of starting empty every time.
        // Named volume (not a bind mount) so it's managed by the container runtime; delete it
        // with `docker volume rm` if the emulator data ever needs a clean reset.
        .WithDataVolume());

var cosmos = cosmosAccount.AddCosmosDatabase("kuulladb");

// Data-plane access for a human operator ("view/edit data in Cosmos"). The production account
// runs with DisableLocalAuth=true — account keys are off, so Data Explorer and every other
// client authenticates with Entra ID and needs an explicit Cosmos SQL role assignment. Aspire
// only wires the managed identities of api/web this way automatically; this additionally grants
// the built-in "Cosmos DB Built-in Data Contributor" role (read + write on all data) to a named
// principal. Publish/deploy-mode only: local dev uses the emulator, which ignores RBAC, and the
// AppHost integration tests boot the model with no Azure provisioner.
if (builder.ExecutionContext.IsPublishMode)
{
    // Object ID of the Entra user (or group) that gets read-write data access. Defaults to the
    // maintainer's own oid — same hardcode-with-override pattern as frontdoor-id above; override
    // with `-p cosmos-data-admin-principal-id=<oid>` or Parameters:cosmos-data-admin-principal-id.
    var cosmosDataAdminPrincipalId = builder.AddParameter(
        "cosmos-data-admin-principal-id",
        value: "c6d08828-a711-4f75-a697-58f177a30bb8",
        secret: false);

    cosmosAccount.ConfigureInfrastructure(infra =>
    {
        var account = infra.GetProvisionableResources().OfType<CosmosDBAccount>().Single();
        var principalId = cosmosDataAdminPrincipalId.AsProvisioningParameter(infra, "cosmosDataAdminPrincipalId");

        // Fixed well-known id of the "Cosmos DB Built-in Data Contributor" data-plane role,
        // present on every SQL API account.
        const string dataContributorRoleId = "00000000-0000-0000-0000-000000000002";
        var roleDefinitionId = (BicepExpression?)BicepFunction.Interpolate(
            $"{account.Id}/sqlRoleDefinitions/{dataContributorRoleId}");

        infra.Add(new NamedCosmosDBSqlRoleAssignment("cosmosDataAdminRoleAssignment")
        {
            Parent = account,
            PrincipalId = principalId,
            RoleDefinitionId = roleDefinitionId,
            Scope = account.Id,
            // The sqlRoleAssignments name segment must be a GUID, deterministic so redeploys don't
            // pile up duplicate assignments.
            NameOverride = BicepFunction.CreateGuid(account.Id, principalId, dataContributorRoleId),
        });
    });
}

var users = cosmos.AddContainer("users", partitionKeyPath: "/id");
var shows = cosmos.AddContainer("shows", partitionKeyPath: "/id");
var episodes = cosmos.AddContainer("episodes", partitionKeyPath: "/ShowId");
var subscriptions = cosmos.AddContainer("subscriptions", partitionKeyPath: "/UserId");
var settings = cosmos.AddContainer("settings", partitionKeyPath: "/id");
var episodeStates = cosmos.AddContainer("episodestates", partitionKeyPath: "/UserId");
var playlists = cosmos.AddContainer("playlists", partitionKeyPath: "/UserId");
var deviceTokens = cosmos.AddContainer("devicetokens", partitionKeyPath: "/UserId");

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

// Public hostnames Front Door serves each app on, and the https origins built from them. Each
// value has more than one use site that must agree — apiPublicUrl is both the API's own
// FrontDoor__PublicUrl (Kuulla.ServiceDefaults rewrites Request.Host to it) and the base address
// the web app's server-side HttpClient targets; the bare hosts are also the FrontDoorCustomDomain
// names wired per origin in the "frontdoor" infrastructure below — so a domain change is one edit.
const string apiPublicHost = "api.kuulla.us";
const string webPublicHost = "app.kuulla.us";
const string apiPublicUrl = "https://" + apiPublicHost;
const string webPublicUrl = "https://" + webPublicHost;

var apiBuilder = builder.AddProject<Projects.Kuulla_Api>("api")
    .WithExternalHttpEndpoints()
    // Front Door's health probe (below) targets this instead of the default "/" so a cold-started
    // replica (#361) doesn't get probed on an arbitrary route.
    .WithHttpProbe(ProbeType.Liveness, "/health")
    .WithEnvironment("FrontDoor__Id", frontDoorId)
    // ACA clobbers X-Forwarded-Host, so the raw *.azurecontainerapps.io hostname can't be
    // recovered from a header — hand the app its public origin directly.
    .WithEnvironment("FrontDoor__PublicUrl", apiPublicUrl)
    .WithReference(cosmos)
    .WithReference(users)
    .WithReference(shows)
    .WithReference(episodes)
    .WithReference(subscriptions)
    .WithReference(settings)
    .WithReference(episodeStates)
    .WithReference(playlists)
    .WithReference(deviceTokens)
    .WithEnvironment("Google__ClientId", googleClientId)
    .WithEnvironment("Google__IosClientId", googleIosClientId);

// Publish-mode only (see the `insights` declaration) — null in Run/test mode.
if (insights is not null)
{
    apiBuilder.WithReference(insights);
}

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
    .PublishAsAzureContainerApp(ScaleToZero);

// Runs the subscribed-podcast feed-polling sweep (milestone #38). Separate from the API so the
// sweep runs exactly once per tick regardless of API replica count.
//
// In publish/deploy mode this becomes an Azure Container Apps *scheduled job* (cron), not an
// always-on container app: the container starts on the cron tick, runs one sweep, and exits.
// Parallelism/ReplicaCompletionCount are pinned to 1 so a single execution runs per tick — that
// single-execution guarantee is the whole point of moving off the per-replica hosted service.
// FeedPolling:RunOnceThenExit tells FeedPollingWorker to do one sweep and stop the host (a job
// execution that never exits would be killed at ReplicaTimeout and marked failed); it's left
// unset locally so `aspire run` keeps the continuous PeriodicTimer poller for dev.
//
// PublishAsScheduledAzureContainerAppJob is a no-op in Run mode (it early-returns unless
// IsPublishMode), like PublishAsAzureContainerApp on api/web — so it needs no IsPublishMode guard
// and doesn't affect the AppHost integration tests. The job's managed identity gets Cosmos
// data-plane access automatically from the .WithReference(cosmos) below, the same way api/web do.
// Every Cosmos container the moved Kuulla.Core services resolve by key — the poller touches the
// same set the API does, so both feed-poller resources below share this wiring.
static IResourceBuilder<ProjectResource> WireFeedPollerDependencies(
    IResourceBuilder<ProjectResource> project,
    IResourceBuilder<Aspire.Hosting.Azure.AzureCosmosDBDatabaseResource> cosmos,
    params IResourceBuilder<Aspire.Hosting.Azure.AzureCosmosDBContainerResource>[] containers)
{
    project.WithReference(cosmos).WaitFor(cosmos);
    foreach (var container in containers)
    {
        project.WithReference(container).WaitFor(container);
    }

    return project;
}

// Once a day at 03:00 UTC for now — a 15-minute sweep costs too much while the subscriber base is
// small. Bump the frequency back up (e.g. "*/15 * * * *") when the cost tradeoff changes.
var feedPollerCron = "0 3 * * *";
var feedPoller = WireFeedPollerDependencies(
        builder.AddProject<Projects.Kuulla_FeedPoller>("feed-poller"),
        cosmos, shows, episodes, subscriptions, settings, episodeStates, playlists, deviceTokens)
    .WithEnvironment(
        "FeedPolling__RunOnceThenExit",
        builder.ExecutionContext.IsPublishMode ? "true" : "false")
    .PublishAsScheduledAzureContainerAppJob(feedPollerCron, (_, job) =>
    {
        job.Configuration.ScheduleTriggerConfig.Parallelism = 1;
        job.Configuration.ScheduleTriggerConfig.ReplicaCompletionCount = 1;
    });

// Publish-mode only (see the `insights` declaration) — null in Run/test mode.
if (insights is not null)
{
    feedPoller.WithReference(insights);
}

if (apnsConfigured)
{
    feedPoller
        .WithEnvironment("Apns__KeyId", apnsKeyId)
        .WithEnvironment("Apns__TeamId", apnsTeamId)
        .WithEnvironment("Apns__BundleId", apnsBundleId)
        .WithEnvironment("Apns__PrivateKey", apnsPrivateKey);
}

// Local-only companion: the same worker wired to run exactly one sweep and exit — the shape the
// ACA scheduled job runs in production. Explicit-start, so `aspire run` doesn't fire it (and
// Kuulla.AppHost.Tests never starts it); hit Start on the `feed-poller-job` resource in the
// dashboard to run a one-shot job against the local Cosmos emulator, watch it sweep, and see it
// go to Finished. Not emitted in publish mode — the real job is `feed-poller` above.
if (!builder.ExecutionContext.IsPublishMode)
{
    var feedPollerJob = WireFeedPollerDependencies(
            builder.AddProject<Projects.Kuulla_FeedPoller>("feed-poller-job"),
            cosmos, shows, episodes, subscriptions, settings, episodeStates, playlists, deviceTokens)
        .WithEnvironment("FeedPolling__RunOnceThenExit", "true")
        .WithExplicitStart();

    if (apnsConfigured)
    {
        feedPollerJob
            .WithEnvironment("Apns__KeyId", apnsKeyId)
            .WithEnvironment("Apns__TeamId", apnsTeamId)
            .WithEnvironment("Apns__BundleId", apnsBundleId)
            .WithEnvironment("Apns__PrivateKey", apnsPrivateKey);
    }
}

var web = builder.AddProject<Projects.Kuulla_Web>("web")
    .WithExternalHttpEndpoints()
    .WithHttpProbe(ProbeType.Liveness, "/health")
    .WithEnvironment("FrontDoor__Id", frontDoorId)
    // See the api resource above — same rewrite, so Google OAuth's redirect_uri is built from
    // app.kuulla.us rather than ACA's raw hostname (which fails redirect_uri_mismatch).
    .WithEnvironment("FrontDoor__PublicUrl", webPublicUrl)
    .WithReference(api)
    // The web app's server-side HttpClient can't use Aspire service discovery to reach the API
    // once the Front Door ID restriction is active on it (#393): those calls land on ACA ingress
    // directly, carry no X-Azure-FDID header, and get 403'd. Hand the web app the API's public
    // Front Door origin so its requests are forwarded with the header like any other. Empty in
    // Run mode -> Web falls back to the "https+http://api" service-discovery address.
    .WithEnvironment("Api__PublicUrl", builder.ExecutionContext.IsPublishMode ? apiPublicUrl : "")
    .WithEnvironment("Authentication__Google__ClientId", googleClientId)
    .WithEnvironment("Authentication__Google__ClientSecret", googleClientSecret)
    .WaitFor(api)
    .PublishAsAzureContainerApp(ScaleToZero);

// Publish-mode only (see the `insights` declaration) — null in Run/test mode.
if (insights is not null)
{
    web.WithReference(insights);
}

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

    AddOrigin(infra, profile, aca.Resource, api.Resource, api.GetEndpoint("http"), apiPublicHost);
    AddOrigin(infra, profile, aca.Resource, web.Resource, web.GetEndpoint("http"), webPublicHost);

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
            // Health probes are deliberately left unset (disabled). Each Front Door edge PoP probes
            // the origin independently, so even at the longest interval this is a near-continuous
            // stream of requests landing on ACA's HTTP ingress — which is exactly the signal KEDA's
            // default HTTP scale rule uses to keep a replica alive. With probes on, api/web never go
            // idle and never scale to zero (#361, #363), defeating the whole point of MinReplicas=0.
            // Front Door allows disabling probes when an origin group has a single origin (as here),
            // and with one origin it always routes there regardless of probe state, so nothing is
            // lost. ACA's own Liveness probe (WithHttpProbe on api/web) still guards replica health;
            // it runs node-local against a running replica and doesn't go through ingress, so it
            // doesn't hold the app awake.
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

        // The public hostname the browser used (api.kuulla.us / app.kuulla.us) isn't forwarded
        // to the app in a header — ACA's ingress overwrites X-Forwarded-Host with its own raw
        // hostname. Each app is instead handed its public origin via the FrontDoor__PublicUrl
        // env var (see the api/web resources above), and Kuulla.ServiceDefaults rewrites
        // Request.Host to it so absolute URLs (Google OAuth's redirect_uri among them) are built
        // from the public hostname rather than ACA's *.azurecontainerapps.io one.
        var route = new FrontDoorRoute($"{originBicepId}Route")
        {
            Parent = endpoint,
            OriginGroupId = originGroup.Id,
            PatternsToMatch = ["/*"],
            ForwardingProtocol = ForwardingProtocol.HttpsOnly,
            // Disabled so the route only answers on the custom domain (api.kuulla.us /
            // app.kuulla.us) — Enabled also serves the endpoint's auto-generated
            // *.z01.azurefd.net default domain, which shouldn't be a reachable public entry point.
            LinkToDefaultDomain = LinkToDefaultDomain.Disabled,
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

/// <summary>
/// <see cref="CosmosDBSqlRoleAssignment"/> exposes <c>Name</c> as a read-only output, but the
/// <c>sqlRoleAssignments</c> ARM resource needs its name segment written (it must be a GUID).
/// This redefines <c>name</c> as a writable property — the same trick Aspire uses internally
/// via its generated <c>*_Derived</c> subclasses.
/// </summary>
file sealed class NamedCosmosDBSqlRoleAssignment(string bicepIdentifier)
    : CosmosDBSqlRoleAssignment(bicepIdentifier)
{
    private BicepValue<string>? _name;

    public BicepValue<string> NameOverride
    {
        get { Initialize(); return _name!; }
        set { Initialize(); _name!.Assign(value); }
    }

    protected override void DefineProvisionableProperties()
    {
        base.DefineProvisionableProperties();
        _name = DefineProperty<string>("Name", ["name"]);
    }
}
