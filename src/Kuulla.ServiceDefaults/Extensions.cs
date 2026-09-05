using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Diagnostics.HealthChecks;
using Microsoft.AspNetCore.HttpOverrides;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Diagnostics.HealthChecks;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.ServiceDiscovery;
using Azure.Monitor.OpenTelemetry.AspNetCore;
using OpenTelemetry;
using OpenTelemetry.Metrics;
using OpenTelemetry.Trace;

namespace Microsoft.Extensions.Hosting;

// Adds common Aspire services: service discovery, resilience, health checks, and OpenTelemetry.
// This project should be referenced by each service project in your solution.
// To learn more about using this project, see https://aka.ms/aspire/service-defaults
public static class Extensions
{
    private const string HealthEndpointPath = "/health";
    private const string AlivenessEndpointPath = "/alive";

    public static TBuilder AddServiceDefaults<TBuilder>(this TBuilder builder) where TBuilder : IHostApplicationBuilder
    {
        builder.ConfigureOpenTelemetry();

        builder.AddDefaultHealthChecks();

        builder.Services.AddServiceDiscovery();

        // Front Door -> ACA is a multi-hop proxy chain whose IPs aren't known/stable, so the
        // usual KnownProxies/KnownNetworks allowlist can't validate it; trust X-Forwarded-* from
        // any hop instead, the same way UseFrontDoorIdRestriction below trusts X-Azure-FDID
        // without an IP check. Without this, ASP.NET Core builds redirect_uri/absolute URLs
        // (Google OAuth's callback URL among them) from ACA's raw *.azurecontainerapps.io
        // Host/http scheme instead of the app.kuulla.us/https that the browser actually requested.
        builder.Services.Configure<ForwardedHeadersOptions>(options =>
        {
            options.ForwardedHeaders = ForwardedHeaders.XForwardedFor
                | ForwardedHeaders.XForwardedProto
                | ForwardedHeaders.XForwardedHost;
            options.KnownIPNetworks.Clear();
            options.KnownProxies.Clear();
        });

        builder.Services.ConfigureHttpClientDefaults(http =>
        {
            // Turn on resilience by default
            http.AddStandardResilienceHandler();

            // Turn on service discovery by default
            http.AddServiceDiscovery();
        });

        // Uncomment the following to restrict the allowed schemes for service discovery.
        // builder.Services.Configure<ServiceDiscoveryOptions>(options =>
        // {
        //     options.AllowedSchemes = ["https"];
        // });

        return builder;
    }

    public static TBuilder ConfigureOpenTelemetry<TBuilder>(this TBuilder builder) where TBuilder : IHostApplicationBuilder
    {
        builder.Logging.AddOpenTelemetry(logging =>
        {
            logging.IncludeFormattedMessage = true;
            logging.IncludeScopes = true;
        });

        builder.Services.AddOpenTelemetry()
            .WithMetrics(metrics =>
            {
                metrics.AddAspNetCoreInstrumentation()
                    .AddHttpClientInstrumentation()
                    .AddRuntimeInstrumentation();
            })
            .WithTracing(tracing =>
            {
                tracing.AddSource(builder.Environment.ApplicationName)
                    .AddAspNetCoreInstrumentation(tracing =>
                        // Exclude health check requests from tracing
                        tracing.Filter = context =>
                            !context.Request.Path.StartsWithSegments(HealthEndpointPath)
                            && !context.Request.Path.StartsWithSegments(AlivenessEndpointPath)
                    )
                    // Uncomment the following line to enable gRPC instrumentation (requires the OpenTelemetry.Instrumentation.GrpcNetClient package)
                    //.AddGrpcClientInstrumentation()
                    .AddHttpClientInstrumentation();
            });

        builder.AddOpenTelemetryExporters();

        return builder;
    }

    private static TBuilder AddOpenTelemetryExporters<TBuilder>(this TBuilder builder) where TBuilder : IHostApplicationBuilder
    {
        var useOtlpExporter = !string.IsNullOrWhiteSpace(builder.Configuration["OTEL_EXPORTER_OTLP_ENDPOINT"]);

        if (useOtlpExporter)
        {
            builder.Services.AddOpenTelemetry().UseOtlpExporter();
        }

        // Populated by the AppHost's AddAzureApplicationInsights resource (issue #366) via
        // WithReference on the api/web projects; unset locally, where the OTLP exporter above
        // (pointed at the Aspire dashboard) is what's active instead.
        if (!string.IsNullOrEmpty(builder.Configuration["APPLICATIONINSIGHTS_CONNECTION_STRING"]))
        {
            builder.Services.AddOpenTelemetry()
                .UseAzureMonitor();
        }

        return builder;
    }

    public static TBuilder AddDefaultHealthChecks<TBuilder>(this TBuilder builder) where TBuilder : IHostApplicationBuilder
    {
        builder.Services.AddHealthChecks()
            // Add a default liveness check to ensure app is responsive
            .AddCheck("self", () => HealthCheckResult.Healthy(), ["live"]);

        return builder;
    }

    public static WebApplication MapDefaultEndpoints(this WebApplication app)
    {
        // Only trust forwarded headers once Front Door is actually in front (mirrors
        // UseFrontDoorIdRestriction's own no-op below) — otherwise anyone reaching this
        // service directly could spoof X-Forwarded-For to impersonate a loopback caller,
        // which is exactly what gates the dev-only token-minting endpoints in Development.
        // Must run before anything that reads Request.Scheme/Host (HTTPS redirection, OAuth
        // challenge/callback URL generation, UseFrontDoorIdRestriction) so they see the
        // original app.kuulla.us/https the browser requested, not ACA's internal hop.
        if (!string.IsNullOrEmpty(app.Configuration["FrontDoor:Id"]))
        {
            app.UseForwardedHeaders();
        }

        // Adding health checks endpoints to applications in non-development environments has security implications.
        // See https://aka.ms/aspire/healthchecks for details before enabling these endpoints in non-development environments.
        if (app.Environment.IsDevelopment())
        {
            // All health checks must pass for app to be considered ready to accept traffic after starting
            app.MapHealthChecks(HealthEndpointPath);

            // Only health checks tagged with the "live" tag must pass for app to be considered alive
            app.MapHealthChecks(AlivenessEndpointPath, new HealthCheckOptions
            {
                Predicate = r => r.Tags.Contains("live")
            });
        }

        return app;
    }

    // Front Door is the only supported public entry point once it's in front of a service (#367)
    // — ACA still exposes its own *.azurecontainerapps.io FQDN, so this rejects anything that
    // reaches it directly instead of through Front Door. Front Door adds this header (and it
    // can't be set by an external caller — ACA only sees it once Front Door has already
    // terminated and re-issued the request) to every request it forwards, health probes included.
    // "FrontDoor:Id" is unset locally and in any environment not yet behind Front Door, so this
    // is a no-op there rather than locking out direct access before Front Door exists.
    public static WebApplication UseFrontDoorIdRestriction(this WebApplication app)
    {
        var frontDoorId = app.Configuration["FrontDoor:Id"];
        if (string.IsNullOrEmpty(frontDoorId))
        {
            return app;
        }

        app.Use(async (context, next) =>
        {
            if (context.Request.Headers.TryGetValue("X-Azure-FDID", out var requestFrontDoorId)
                && requestFrontDoorId == frontDoorId)
            {
                await next(context);
                return;
            }

            context.Response.StatusCode = StatusCodes.Status403Forbidden;
        });

        return app;
    }
}
