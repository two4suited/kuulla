#pragma warning disable ASPIRECOSMOSDB001 // RunAsPreviewEmulator is experimental.

var builder = DistributedApplication.CreateBuilder(args);

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

var redis = builder.AddRedis("redis");

// Google OAuth credentials for "Login with Google" (milestone #1, issues #5-#8).
// Values come from Parameters:<name> in the AppHost's user secrets locally —
// see the `dotnet user-secrets set` commands below once the GCP OAuth app exists.
var googleClientId = builder.AddParameter("google-client-id");
var googleClientSecret = builder.AddParameter("google-client-secret", secret: true);
var googleIosClientId = builder.AddParameter("google-ios-client-id");

var api = builder.AddProject<Projects.Kuulla_Api>("api")
    .WithReference(cosmos)
    .WithReference(users)
    .WithReference(shows)
    .WithReference(episodes)
    .WithReference(subscriptions)
    .WithReference(settings)
    .WithReference(episodeStates)
    .WithReference(playlists)
    .WithReference(redis)
    .WithEnvironment("Google__ClientId", googleClientId)
    .WithEnvironment("Google__IosClientId", googleIosClientId)
    .WaitFor(cosmos)
    .WaitFor(users)
    .WaitFor(shows)
    .WaitFor(episodes)
    .WaitFor(subscriptions)
    .WaitFor(settings)
    .WaitFor(episodeStates)
    .WaitFor(playlists)
    .WaitFor(redis);

builder.AddProject<Projects.Kuulla_Web>("web")
    .WithExternalHttpEndpoints()
    .WithReference(api)
    .WithEnvironment("Authentication__Google__ClientId", googleClientId)
    .WithEnvironment("Authentication__Google__ClientSecret", googleClientSecret)
    .WaitFor(api);

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

builder.Build().Run();
