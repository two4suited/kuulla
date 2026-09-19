using Kuulla.Core;
using Kuulla.FeedPoller;

var builder = Host.CreateApplicationBuilder(args);

builder.AddServiceDefaults();

// Same Cosmos client + keyed containers the API registers — the moved domain services resolve
// their containers by key ([FromKeyedServices("shows")] etc.), so the host has to supply them.
builder.AddAzureCosmosClient("kuulladb");
builder.AddKeyedAzureCosmosContainer("shows");
builder.AddKeyedAzureCosmosContainer("episodes");
builder.AddKeyedAzureCosmosContainer("subscriptions");
builder.AddKeyedAzureCosmosContainer("settings");
builder.AddKeyedAzureCosmosContainer("episodestates");
builder.AddKeyedAzureCosmosContainer("playlists");
builder.AddKeyedAzureCosmosContainer("devicetokens");

builder.Services.AddKuullaCore(builder.Configuration);
// The poller is the path that sends the new-episode push for subscribers who never open the app,
// so it wires the same APNs (or no-op) sender the API does.
builder.Services.AddKuullaNotifications(builder.Configuration);

builder.Services.AddHostedService<FeedPollingWorker>();

var host = builder.Build();
host.Run();
