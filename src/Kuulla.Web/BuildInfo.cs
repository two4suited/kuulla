using System.Reflection;
using System.Text.RegularExpressions;

namespace Kuulla.Web;

/// <summary>
/// Build identity for the running web app. On a release build (from a CalVer tag) the
/// <see cref="AssemblyInformationalVersionAttribute"/> is <c>YYYY.M.N+&lt;sha&gt;</c>; otherwise it is
/// <c>&lt;default version&gt;+&lt;sha&gt;</c> and the release segment shows as <c>dev</c>. Both segments are
/// embedded at build time — see Kuulla.Web.csproj.
/// </summary>
public static partial class BuildInfo
{
    /// <summary>
    /// Display version: the CalVer release plus the short commit, e.g. <c>2026.9.0+a1b2c3d</c>, or
    /// <c>dev+a1b2c3d</c> for a local / main build, or <c>dev</c> when no commit is available.
    /// </summary>
    public static string Version { get; } = FormatVersion(
        typeof(BuildInfo).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion);

    internal static string FormatVersion(string? informationalVersion)
    {
        // InformationalVersion is "<version>+<sha>" (see Kuulla.Web.csproj). On a release build
        // <version> is the CalVer tag; otherwise it is the SDK default and we substitute "dev".
        var parts = informationalVersion?.Split('+', 2) ?? [];
        var version = parts.Length > 0 ? parts[0] : null;
        var revision = parts.Length > 1 ? parts[1] : null;

        var release = !string.IsNullOrEmpty(version) && CalVerPattern().IsMatch(version) ? version : "dev";
        if (string.IsNullOrEmpty(revision))
        {
            return release;
        }

        return $"{release}+{revision[..Math.Min(revision.Length, 7)]}";
    }

    [GeneratedRegex(@"^\d{4}\.\d{1,2}\.\d+$")]
    private static partial Regex CalVerPattern();
}
