using Newtonsoft.Json;

namespace Kuulla.Api.Models;

// Id is the Google "sub" claim — a stable, immutable per-account identifier, unlike email
// which can change (Workspace domain moves, account recovery, etc.) and shouldn't be a key.
// The Cosmos SDK's default serializer is Newtonsoft-based (not System.Text.Json), so it's
// Newtonsoft's [JsonProperty] that controls the wire format Cosmos requires ("id", not "Id").
public record User(
    [property: JsonProperty("id")] string Id,
    string Email,
    string? Name,
    string? PictureUrl,
    DateTimeOffset CreatedAt,
    DateTimeOffset LastLoginAt);
