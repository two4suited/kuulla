using Kuulla.Core.Models;

namespace Kuulla.Core.Services;

public record PodcastFeedContent(string? Description, IReadOnlyList<Episode> Episodes);
