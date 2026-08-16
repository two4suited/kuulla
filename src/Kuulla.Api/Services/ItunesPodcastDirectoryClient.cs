using System.Globalization;
using System.Net.Http.Json;
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
            .Select(r => new Show(
                r.CollectionId!.Value.ToString(CultureInfo.InvariantCulture),
                r.CollectionName ?? r.TrackName ?? "Untitled",
                r.ArtistName ?? "Unknown",
                r.FeedUrl!,
                r.ArtworkUrl600,
                Description: null,
                Categories: r.Genres is { Count: > 0 } ? r.Genres : r.PrimaryGenreName is null ? [] : [r.PrimaryGenreName]))
            .ToList();
    }

    private record ItunesSearchResponse([property: JsonPropertyName("results")] List<ItunesSearchResult>? Results);

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
