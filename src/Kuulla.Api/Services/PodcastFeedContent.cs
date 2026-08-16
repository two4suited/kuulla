using Kuulla.Api.Models;

namespace Kuulla.Api.Services;

public record PodcastFeedContent(string? Description, IReadOnlyList<Episode> Episodes);
