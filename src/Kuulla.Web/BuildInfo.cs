using System.Reflection;

namespace Kuulla.Web;

/// <summary>
/// Build identity for the running web app. The git commit SHA is embedded into
/// <see cref="AssemblyInformationalVersionAttribute"/> at build time (see Kuulla.Web.csproj).
/// </summary>
public static class BuildInfo
{
    /// <summary>
    /// Short display version, e.g. <c>v1a2b3c4</c>, or <c>dev</c> for a local build with no SHA.
    /// </summary>
    public static string Version { get; } = ResolveVersion();

    private static string ResolveVersion()
    {
        var informationalVersion = typeof(BuildInfo).Assembly
            .GetCustomAttribute<AssemblyInformationalVersionAttribute>()?
            .InformationalVersion;

        var sha = informationalVersion?.Split('+') is [_, var revision, ..] ? revision : informationalVersion;
        if (string.IsNullOrEmpty(sha))
        {
            return "dev";
        }

        return $"v{sha[..Math.Min(sha.Length, 7)]}";
    }
}
