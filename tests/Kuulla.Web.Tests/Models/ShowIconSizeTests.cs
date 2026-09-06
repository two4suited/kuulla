using Kuulla.Web.Models;

namespace Kuulla.Web.Tests.Models;

public class ShowIconSizeTests
{
    [Fact]
    public void Default_IsLarge() => Assert.Equal(ShowIconSize.Large, ShowIconSizes.Default);

    [Fact]
    public void Large_KeepsOriginalRowColsClass() =>
        // The grid that shipped before this option existed used "row-cols-2 row-cols-md-4".
        Assert.Equal("row-cols-2 row-cols-md-4", ShowIconSize.Large.RowColsClass());

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("gigantic")]
    public void Parse_FallsBackToDefault_ForMissingOrUnknownValue(string? raw) =>
        Assert.Equal(ShowIconSizes.Default, ShowIconSizes.Parse(raw));

    [Theory]
    [InlineData(ShowIconSize.Small)]
    [InlineData(ShowIconSize.Medium)]
    [InlineData(ShowIconSize.Large)]
    public void Parse_RoundTripsStoredValue(ShowIconSize size) =>
        Assert.Equal(size, ShowIconSizes.Parse(size.ToStorageString()));

    [Fact]
    public void SmallerSize_FitsMoreShowsPerRow()
    {
        Assert.True(MdColumns(ShowIconSize.Small) > MdColumns(ShowIconSize.Medium));
        Assert.True(MdColumns(ShowIconSize.Medium) > MdColumns(ShowIconSize.Large));

        // The md breakpoint column count is the trailing number in "... row-cols-md-N".
        static int MdColumns(ShowIconSize size) =>
            int.Parse(size.RowColsClass().Split("row-cols-md-")[1]);
    }

    [Fact]
    public void All_ListsEverySizeSmallToLarge() =>
        Assert.Equal([ShowIconSize.Small, ShowIconSize.Medium, ShowIconSize.Large], ShowIconSizes.All);
}
