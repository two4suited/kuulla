#pragma warning disable ASPIRECOSMOSDB001 // RunAsPreviewEmulator is experimental.

var builder = DistributedApplication.CreateBuilder(args);

var cosmos = builder.AddAzureCosmosDB("cosmos")
    .RunAsPreviewEmulator(emulator => emulator
        .WithDataExplorer()
        // Without this, the emulator's self-signed cert/listener binds to whatever address it
        // autodetects inside the container, which can be wrong in headless CI runners and
        // produces a TLS handshake failure ("corrupted frame") on the very first real query —
        // Aspire's own health check passes because it doesn't exercise the same path.
        .WithEnvironment("AZURE_COSMOS_EMULATOR_IP_ADDRESS_OVERRIDE", "127.0.0.1"))
    .AddCosmosDatabase("kuulladb");

var users = cosmos.AddContainer("users", partitionKeyPath: "/id");
var shows = cosmos.AddContainer("shows", partitionKeyPath: "/id");
var episodes = cosmos.AddContainer("episodes", partitionKeyPath: "/ShowId");
var subscriptions = cosmos.AddContainer("subscriptions", partitionKeyPath: "/UserId");
var settings = cosmos.AddContainer("settings", partitionKeyPath: "/id");

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
    .WithReference(redis)
    .WithEnvironment("Google__ClientId", googleClientId)
    .WithEnvironment("Google__IosClientId", googleIosClientId)
    .WaitFor(cosmos)
    .WaitFor(users)
    .WaitFor(shows)
    .WaitFor(episodes)
    .WaitFor(subscriptions)
    .WaitFor(settings)
    .WaitFor(redis);

builder.AddProject<Projects.Kuulla_Web>("web")
    .WithExternalHttpEndpoints()
    .WithReference(api)
    .WithEnvironment("Authentication__Google__ClientId", googleClientId)
    .WithEnvironment("Authentication__Google__ClientSecret", googleClientSecret)
    .WaitFor(api);

builder.Build().Run();
