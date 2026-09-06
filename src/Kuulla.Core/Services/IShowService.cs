using Kuulla.Core.Models;

namespace Kuulla.Core.Services;

public interface IShowService
{
    Task<Show?> GetByIdAsync(string id, CancellationToken cancellationToken);

    Task<IReadOnlyList<Show>> SearchAsync(string query, CancellationToken cancellationToken);

    Task<IReadOnlyList<Show>> GetTrendingAsync(string? category, CancellationToken cancellationToken);
}
