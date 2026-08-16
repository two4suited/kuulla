using Kuulla.Api.Models;

namespace Kuulla.Api.Services;

public interface IUserService
{
    Task<User> GetOrCreateUserAsync(
        string googleSubject,
        string email,
        string? name,
        string? pictureUrl,
        CancellationToken cancellationToken);
}
