var builder = DistributedApplication.CreateBuilder(args);

var cosmos = builder.AddAzureCosmosDB("cosmos")
    .RunAsEmulator()
    .AddCosmosDatabase("kuulladb");

var redis = builder.AddRedis("redis");

var api = builder.AddProject<Projects.Kuulla_Api>("api")
    .WithReference(cosmos)
    .WithReference(redis)
    .WaitFor(cosmos)
    .WaitFor(redis);

builder.AddProject<Projects.Kuulla_Web>("web")
    .WithExternalHttpEndpoints()
    .WithReference(api)
    .WaitFor(api);

builder.Build().Run();
