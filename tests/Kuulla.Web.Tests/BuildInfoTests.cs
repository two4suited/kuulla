namespace Kuulla.Web.Tests;

public class BuildInfoTests
{
    [Theory]
    [InlineData("2026.9.0+a1b2c3d", "2026.9.0+a1b2c3d")]
    [InlineData("2026.10.3+a1b2c3d", "2026.10.3+a1b2c3d")]
    [InlineData("2026.9.0+a1b2c3d4e5f6", "2026.9.0+a1b2c3d")] // full sha is truncated to 7
    [InlineData("2026.9.0", "2026.9.0")] // no sha segment
    public void FormatVersion_release_build_shows_calver(string informational, string expected)
    {
        Assert.Equal(expected, BuildInfo.FormatVersion(informational));
    }

    [Theory]
    [InlineData("1.0.0+a1b2c3d", "dev+a1b2c3d")]
    [InlineData("1.0.0", "dev")]
    [InlineData("8.0.0-preview+a1b2c3d", "dev+a1b2c3d")]
    [InlineData(null, "dev")]
    [InlineData("", "dev")]
    public void FormatVersion_non_release_build_shows_dev(string? informational, string expected)
    {
        Assert.Equal(expected, BuildInfo.FormatVersion(informational));
    }
}
