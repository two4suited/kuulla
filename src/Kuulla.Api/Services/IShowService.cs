using Kuulla.Api.Models;

namespace Kuulla.Api.Services;

public interface IShowService
{
    Task<Show?> GetByIdAsync(string id, CancellationToken cancellationToken);

    Task<IReadOnlyList<Show>> SearchAsync(string query, CancellationToken cancellationToken);
}
