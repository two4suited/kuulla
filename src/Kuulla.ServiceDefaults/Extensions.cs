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
        // without an IP check. This recovers the client IP (X-Forwarded-For) and the original
        // https scheme (X-Forwarded-Proto) the browser used through Front Door.
        //
        // The host is handled separately (see MapDefaultEndpoints, FrontDoor:PublicUrl): ACA's
        // own ingress overwrites X-Forwarded-Host with its raw *.azurecontainerapps.io hostname,
        // so it can't be trusted here. Each app is instead told its own public origin via config.
        builder.Services.Configure<ForwardedHeadersOptions>(options =>
        {
            options.ForwardedHeaders = ForwardedHeaders.XForwardedFor
                | ForwardedHeaders.XForwardedProto;
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
        // original https scheme the browser requested, not ACA's internal http hop.
        if (!string.IsNullOrEmpty(app.Configuration["FrontDoor:Id"]))
        {
            app.UseForwardedHeaders();
        }

        // The host can't be recovered from a forwarded header behind Front Door: ACA's ingress
        // overwrites X-Forwarded-Host with its own raw *.azurecontainerapps.io hostname before
        // the request reaches this app. Instead, each app is handed its own public origin
        // (https://api.kuulla.us / https://app.kuulla.us) via config at deploy time (AppHost.cs),
        // and Request.Host is rewritten to it here. Without this, ASP.NET Core builds absolute
        // URLs — Google OAuth's redirect_uri among them — from the raw ACA hostname, which fails
        // redirect_uri_mismatch against what's registered with Google. Runs after
        // UseForwardedHeaders so Request.Scheme is already the browser's https by this point.
        if (Uri.TryCreate(app.Configuration["FrontDoor:PublicUrl"], UriKind.Absolute, out var publicUrl))
        {
            var publicHost = new HostString(publicUrl.Authority);
            app.Use((context, next) =>
            {
                context.Request.Scheme = publicUrl.Scheme;
                context.Request.Host = publicHost;
                return next(context);
            });
        }

        // Adding health checks endpoints to applications in non-development environments has security implications.
        // See https://aka.ms/aspire/healthchecks for details before enabling these endpoints in non-development environments.
        // NOTE: api and web each map their own always-200 GET /health in Program.cs (independent of any
        // downstream Cosmos/Redis health check, so the liveness probe doesn't fail during Redis scale-to-zero) —
        // that's what ACA's liveness probe and Front Door's origin probe target. Mapping MapHealthChecks on the
        // same "/health" route here would be an ambiguous-route conflict, so this stays Development-only.
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
    // terminated and re-issued the request) to every request it forwards, its own origin health
    // probe included.
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
            // ACA's own liveness/readiness probes hit the container directly on the health paths
            // without going through Front Door, so they can never carry X-Azure-FDID — 403'ing
            // them makes every deployed revision fail its liveness probe, never go ready, and
            // leaves traffic pinned to the previous revision. Let those paths through: api/web
            // map them to an always-200 handler with no sensitive body. (Front Door's origin
            // probe carries the header like any forwarded request, so it doesn't rely on this.)
            var path = context.Request.Path;
            if (path.Equals(HealthEndpointPath, StringComparison.OrdinalIgnoreCase)
                || path.Equals(AlivenessEndpointPath, StringComparison.OrdinalIgnoreCase))
            {
                await next(context);
                return;
            }

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
