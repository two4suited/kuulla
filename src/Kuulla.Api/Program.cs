var builder = WebApplication.CreateBuilder(args);

builder.AddServiceDefaults();
builder.AddAzureCosmosClient("kuulladb");
builder.AddRedisClient("redis");

var app = builder.Build();

app.MapDefaultEndpoints();

app.MapGet("/health", () => Results.Ok(new { status = "healthy" }));

app.Run();
