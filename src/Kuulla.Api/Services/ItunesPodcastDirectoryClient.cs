using System.Globalization;
using System.Net.Http.Json;
using System.Text.Json;
using System.Text.Json.Serialization;
using Kuulla.Api.Models;

namespace Kuulla.Api.Services;

// Apple's iTunes Search API: free, no API key, no signup — covers the full public
// podcast catalog. https://performance-partners.apple.com/search-api
public class ItunesPodcastDirectoryClient(HttpClient httpClient) : IPodcastDirectoryClient
{
    public async Task<IReadOnlyList<Show>> SearchAsync(string query, CancellationToken cancellationToken)
    {
        var url = $"search?media=podcast&entity=podcast&limit=25&term={Uri.EscapeDataString(query)}";
        var response = await httpClient.GetFromJsonAsync<ItunesSearchResponse>(url, cancellationToken);

        if (response?.Results is null)
        {
            return [];
        }

        return response.Results
            .Where(r => r.CollectionId is not null && !string.IsNullOrEmpty(r.FeedUrl))
            .Select(MapResult)
            .ToList();
    }

    public async Task<IReadOnlyList<Show>> GetTrendingAsync(string? category, CancellationToken cancellationToken)
    {
        var chartsUrl = category is null
            ? "us/rss/toppodcasts/limit=25/json"
            : $"us/rss/toppodcasts/limit=25/genre={Uri.EscapeDataString(category)}/json";

        var chartsResponse = await httpClient.GetFromJsonAsync<ItunesChartsResponse>(chartsUrl, cancellationToken);
        var ids = chartsResponse?.Feed?.Entries?.Select(e => e.Id.Attributes.CollectionId).Where(id => !string.IsNullOrEmpty(id)).ToList();
        if (ids is not { Count: > 0 })
        {
            return [];
        }

        // The charts feed doesn't include feedUrl, so resolve full records via the lookup
        // endpoint and reorder to match the charts' trending order.
        var lookupUrl = $"lookup?id={string.Join(',', ids)}";
        var lookupResponse = await httpClient.GetFromJsonAsync<ItunesSearchResponse>(lookupUrl, cancellationToken);
        var byId = (lookupResponse?.Results ?? [])
            .Where(r => r.CollectionId is not null && !string.IsNullOrEmpty(r.FeedUrl))
            .ToDictionary(r => r.CollectionId!.Value.ToString(CultureInfo.InvariantCulture));

        return ids
            .Where(byId.ContainsKey)
            .Select(id => MapResult(byId[id]))
            .ToList();
    }

    private static Show MapResult(ItunesSearchResult r) => new(
        r.CollectionId!.Value.ToString(CultureInfo.InvariantCulture),
        r.CollectionName ?? r.TrackName ?? "Untitled",
        r.ArtistName ?? "Unknown",
        r.FeedUrl!,
        r.ArtworkUrl600,
        Description: null,
        Categories: r.Genres is { Count: > 0 } ? r.Genres : r.PrimaryGenreName is null ? [] : [r.PrimaryGenreName]);

    private record ItunesSearchResponse([property: JsonPropertyName("results")] List<ItunesSearchResult>? Results);

    private record ItunesChartsResponse([property: JsonPropertyName("feed")] ItunesChartsFeed? Feed);

    private record ItunesChartsFeed(
        [property: JsonPropertyName("entry"), JsonConverter(typeof(SingleOrArrayConverter<ItunesChartsEntry>))] List<ItunesChartsEntry>? Entries);

    private record ItunesChartsEntry([property: JsonPropertyName("id")] ItunesChartsEntryId Id);

    private record ItunesChartsEntryId([property: JsonPropertyName("attributes")] ItunesChartsEntryIdAttributes Attributes);

    private record ItunesChartsEntryIdAttributes([property: JsonPropertyName("im:id")] string CollectionId);

    // Apple's toppodcasts RSS-to-JSON feed serializes a single-result "entry" as a bare
    // object instead of a one-element array, so a narrow genre with one match would
    // otherwise fail to deserialize.
    private class SingleOrArrayConverter<T> : JsonConverter<List<T>?>
    {
        public override List<T>? Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
            reader.TokenType == JsonTokenType.StartArray
                ? JsonSerializer.Deserialize<List<T>>(ref reader, options)
                : [JsonSerializer.Deserialize<T>(ref reader, options)!];

        public override void Write(Utf8JsonWriter writer, List<T>? value, JsonSerializerOptions options) =>
            JsonSerializer.Serialize(writer, value, options);
    }

    private record ItunesSearchResult(
        [property: JsonPropertyName("collectionId")] long? CollectionId,
        [property: JsonPropertyName("collectionName")] string? CollectionName,
        [property: JsonPropertyName("trackName")] string? TrackName,
        [property: JsonPropertyName("artistName")] string? ArtistName,
        [property: JsonPropertyName("feedUrl")] string? FeedUrl,
        [property: JsonPropertyName("artworkUrl600")] string? ArtworkUrl600,
        [property: JsonPropertyName("primaryGenreName")] string? PrimaryGenreName,
        [property: JsonPropertyName("genres")] List<string>? Genres);
}
