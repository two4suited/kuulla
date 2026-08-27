using System.Net;
using System.Net.Sockets;

namespace Kuulla.Api.Services;

// Fetches a URL that came from untrusted feed XML (a podcast:chapters document, a
// podcast:transcript document, ...) while defending against SSRF: the URL must be an absolute
// http(s) address whose host resolves entirely to publicly-routable IPs, and every redirect hop
// is re-validated the same way before being followed rather than letting the runtime chase one
// transparently past the guard.
//
// Shared by PodcastFeedClient (chapters) and TranscriptService (transcripts) so the hardening
// that accreted on this logic lives in exactly one place.
public sealed class PublicResourceFetcher(
    ILogger<PublicResourceFetcher> logger,
    // Overridable purely for testing — production always resolves through real DNS. Tests supply
    // canned results so guard behavior ("a hostname resolving to a private address is rejected")
    // is verifiable without depending on real DNS or a live network.
    Func<string, CancellationToken, Task<IPAddress[]>>? hostResolver = null,
    // Overridable purely for testing, same reason. Production sends through the "external-resource"
    // named client (auto-redirect disabled, registered in Program.cs) rather than a client that
    // follows redirects itself, so SendAsync can see and re-validate every hop. Routed through
    // IHttpClientFactory so it still inherits the app's HTTP defaults — resilience handler,
    // service discovery, OTel instrumentation — from ConfigureHttpClientDefaults in ServiceDefaults.
    Func<Uri, CancellationToken, Task<HttpResponseMessage>>? sendAsync = null,
    IHttpClientFactory? httpClientFactory = null)
{
    public const string HttpClientName = "external-resource";
    private const int MaxRedirects = 5;

    private readonly Func<string, CancellationToken, Task<IPAddress[]>> _resolveHostAsync =
        hostResolver ?? Dns.GetHostAddressesAsync;
    private readonly Func<Uri, CancellationToken, Task<HttpResponseMessage>> _sendAsync =
        sendAsync ?? MakeDefaultSendAsync(httpClientFactory);

    // Failing fast at construction rather than deferring a null-forgiving httpClientFactory! to
    // first use — a caller that skips both sendAsync and httpClientFactory (real DI always supplies
    // the latter) gets an immediate, self-explanatory error instead of a NullReferenceException on
    // the first fetch. Parameter named distinctly so nameof(httpClientFactory) below keeps
    // referring to the constructor parameter.
    private static Func<Uri, CancellationToken, Task<HttpResponseMessage>> MakeDefaultSendAsync(
        IHttpClientFactory? factory)
    {
        if (factory is null)
        {
            throw new InvalidOperationException(
                $"{nameof(PublicResourceFetcher)} requires either {nameof(sendAsync)} or {nameof(httpClientFactory)} to be provided.");
        }

        return (uri, ct) => factory.CreateClient(HttpClientName)
            .GetAsync(uri, HttpCompletionOption.ResponseHeadersRead, ct);
    }

    // Rejects anything that isn't an absolute http(s) URL pointed at a public host before this
    // server fetches it. Resolves a hostname (rather than only checking IP literals) and rejects
    // it if ANY resolved address is non-public — otherwise a hostname that resolves to an internal
    // address (DNS rebinding, a nip.io-style domain) would sail straight through.
    public async Task<Uri?> ResolveFetchableUrlAsync(string? url, CancellationToken cancellationToken)
    {
        if (string.IsNullOrEmpty(url) || !Uri.TryCreate(url, UriKind.Absolute, out var parsed))
        {
            return null;
        }

        if (parsed.Scheme != Uri.UriSchemeHttp && parsed.Scheme != Uri.UriSchemeHttps)
        {
            return null;
        }

        // Reject userinfo (https://<user>:<pass>@host/...) outright — GetAsync would send it, and
        // this URL comes from an untrusted feed, so a crafted one could otherwise leak credentials
        // into the warning logs below on a failed fetch.
        if (!string.IsNullOrEmpty(parsed.UserInfo))
        {
            return null;
        }

        // "localhost" resolves to loopback on essentially every system without a DNS query, so
        // check it directly rather than depending on the resolver getting it right.
        if (parsed.IsLoopback || string.Equals(parsed.Host, "localhost", StringComparison.OrdinalIgnoreCase))
        {
            return null;
        }

        IPAddress[] addresses;
        if (IPAddress.TryParse(parsed.Host, out var literalAddress))
        {
            addresses = [literalAddress];
        }
        else
        {
            try
            {
                addresses = await _resolveHostAsync(parsed.Host, cancellationToken);
            }
            catch (Exception ex) when (ex is SocketException or ArgumentException)
            {
                return null;
            }
        }

        return addresses.Length > 0 && addresses.All(IsPubliclyRoutable) ? parsed : null;
    }

    // Fetches validatedUrl (which must have come from ResolveFetchableUrlAsync), following and
    // re-validating every redirect hop. Returns a successful, non-redirect response the caller is
    // responsible for disposing, or null if the resource is unreachable, a redirect target fails
    // the SSRF guard, there are too many redirects, or the final status is not success.
    // diagnosticLabel names the resource kind ("podcast:chapters", "podcast:transcript") in logs.
    public async Task<HttpResponseMessage?> SendAsync(
        Uri validatedUrl, string diagnosticLabel, CancellationToken cancellationToken)
    {
        var currentUrl = validatedUrl;
        try
        {
            for (var redirectCount = 0; ; redirectCount++)
            {
                var response = await _sendAsync(currentUrl, cancellationToken);

                if (IsRedirect(response.StatusCode))
                {
                    using (response)
                    {
                        if (redirectCount >= MaxRedirects || response.Headers.Location is null)
                        {
                            logger.LogWarning(
                                "Too many redirects (or a redirect with no Location) fetching {ResourceLabel} from {Url}",
                                diagnosticLabel, validatedUrl);
                            return null;
                        }

                        var nextUrl = response.Headers.Location.IsAbsoluteUri
                            ? response.Headers.Location
                            : new Uri(currentUrl, response.Headers.Location);
                        var validatedNextUrl = await ResolveFetchableUrlAsync(nextUrl.ToString(), cancellationToken);
                        if (validatedNextUrl is null)
                        {
                            // nextUrl is logged sanitized (not validatedNextUrl, which is null
                            // here) — one reason validation fails is exactly that nextUrl carries
                            // userinfo.
                            logger.LogWarning(
                                "Redirect from {ResourceLabel} {Url} to {RedirectUrl} was rejected by the SSRF guard",
                                diagnosticLabel, validatedUrl, SanitizeForLogging(nextUrl));
                            return null;
                        }

                        currentUrl = validatedNextUrl;
                        continue;
                    }
                }

                if (!response.IsSuccessStatusCode)
                {
                    logger.LogWarning(
                        "Fetching {ResourceLabel} from {Url} returned {StatusCode}",
                        diagnosticLabel, validatedUrl, (int)response.StatusCode);
                    response.Dispose();
                    return null;
                }

                return response;
            }
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            logger.LogWarning(ex, "Failed to fetch {ResourceLabel} from {Url}", diagnosticLabel, validatedUrl);
            return null;
        }
    }

    // Named for what it returns true for (a fetchable public address), not what it excludes — the
    // exclusion list has grown well past "private or loopback" (multicast, TEST-NET, benchmarking,
    // CGNAT, documentation ranges, ...).
    private static bool IsPubliclyRoutable(IPAddress address)
    {
        // An IPv4-mapped IPv6 address (::ffff:10.0.0.1) must be evaluated as its embedded IPv4
        // form — otherwise it skips the IPv4 range checks below and only IsLoopback() would catch
        // it.
        if (address.IsIPv4MappedToIPv6)
        {
            address = address.MapToIPv4();
        }

        if (IPAddress.IsLoopback(address))
        {
            return false;
        }

        if (IPAddress.Any.Equals(address) || IPAddress.IPv6Any.Equals(address) || address.IsIPv6Multicast)
        {
            return false;
        }

        var bytes = address.GetAddressBytes();
        var isNonPublic = address.AddressFamily switch
        {
            AddressFamily.InterNetwork =>
                bytes[0] == 0 // "this network" (includes 0.0.0.0)
                || bytes[0] == 10
                || (bytes[0] == 172 && bytes[1] is >= 16 and <= 31)
                || (bytes[0] == 192 && bytes[1] == 168)
                || (bytes[0] == 169 && bytes[1] == 254) // link-local
                || (bytes[0] == 100 && bytes[1] is >= 64 and <= 127) // CGNAT (100.64.0.0/10)
                || (bytes[0] == 198 && bytes[1] is 18 or 19) // benchmarking (198.18.0.0/15)
                || (bytes[0] == 192 && bytes[1] == 0 && bytes[2] == 2) // TEST-NET-1 (192.0.2.0/24)
                || (bytes[0] == 198 && bytes[1] == 51 && bytes[2] == 100) // TEST-NET-2 (198.51.100.0/24)
                || (bytes[0] == 203 && bytes[1] == 0 && bytes[2] == 113) // TEST-NET-3 (203.0.113.0/24)
                || bytes[0] is >= 224 and <= 255, // multicast (224-239) + reserved Class E (240-255)
            // fc00::/7 (unique-local) covers both fc00::/8 and fd00::/8 — checking the top 7 bits
            // directly rather than IsIPv6SiteLocal, which only recognizes the deprecated fec0::/10
            // range. The explicit byte check is the IPv6 documentation range (2001:db8::/32).
            AddressFamily.InterNetworkV6 =>
                address.IsIPv6LinkLocal || address.IsIPv6SiteLocal || (bytes[0] & 0xFE) == 0xFC
                || (bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] == 0x0D && bytes[3] == 0xB8),
            _ => true, // an unrecognized address family is treated as non-routable, not public
        };

        return !isNonPublic;
    }

    private static bool IsRedirect(HttpStatusCode statusCode) =>
        statusCode is HttpStatusCode.MovedPermanently or HttpStatusCode.Found or HttpStatusCode.SeeOther
            or HttpStatusCode.TemporaryRedirect or HttpStatusCode.PermanentRedirect;

    // Strips userinfo before a URL that hasn't passed the SSRF guard reaches a log line — an
    // untrusted redirect Location could otherwise leak credentials into logs.
    private static string SanitizeForLogging(Uri uri) =>
        string.IsNullOrEmpty(uri.UserInfo)
            ? uri.ToString()
            : new UriBuilder(uri) { UserName = "", Password = "" }.Uri.ToString();
}
