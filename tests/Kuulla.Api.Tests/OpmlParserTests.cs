using Kuulla.Api.Services;

namespace Kuulla.Api.Tests;

public class OpmlParserTests
{
    private static string Opml(string body) => $"""
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="2.0">
          <head><title>Subscriptions</title></head>
          <body>
        {body}
          </body>
        </opml>
        """;

    [Fact]
    public void Parse_FlatList_ReturnsEveryFeedInOrder()
    {
        var feeds = OpmlParser.Parse(Opml("""
            <outline type="rss" text="Show A" title="Show A" xmlUrl="https://a.example/feed" />
            <outline type="rss" text="Show B" xmlUrl="https://b.example/feed" />
            """));

        Assert.Collection(feeds,
            f => { Assert.Equal("Show A", f.Title); Assert.Equal("https://a.example/feed", f.FeedUrl); },
            f => { Assert.Equal("Show B", f.Title); Assert.Equal("https://b.example/feed", f.FeedUrl); });
    }

    [Fact]
    public void Parse_NestedFolders_FlattensFeedsAndIgnoresFolderOutlines()
    {
        var feeds = OpmlParser.Parse(Opml("""
            <outline text="Tech">
              <outline type="rss" text="Show A" xmlUrl="https://a.example/feed" />
              <outline text="Nested">
                <outline type="rss" text="Show B" xmlUrl="https://b.example/feed" />
              </outline>
            </outline>
            <outline type="rss" text="Show C" xmlUrl="https://c.example/feed" />
            """));

        Assert.Equal(
            new[] { "https://a.example/feed", "https://b.example/feed", "https://c.example/feed" },
            feeds.Select(f => f.FeedUrl));
    }

    [Fact]
    public void Parse_DuplicateFeedsWithinFile_AreCollapsedByNormalizedUrlKeepingTheFirst()
    {
        var feeds = OpmlParser.Parse(Opml("""
            <outline type="rss" text="Canonical" xmlUrl="https://a.example/feed" />
            <outline type="rss" text="Same feed, http + slash" xmlUrl="http://a.example/feed/" />
            """));

        var feed = Assert.Single(feeds);
        Assert.Equal("Canonical", feed.Title);
        Assert.Equal("https://a.example/feed", feed.FeedUrl);
    }

    [Fact]
    public void Parse_OutlineWithNoXmlUrl_IsSkipped()
    {
        var feeds = OpmlParser.Parse(Opml("""
            <outline text="Just a heading" />
            <outline type="link" text="A link" url="https://example.com" />
            <outline type="rss" text="Real feed" xmlUrl="https://a.example/feed" />
            """));

        var feed = Assert.Single(feeds);
        Assert.Equal("https://a.example/feed", feed.FeedUrl);
    }

    [Fact]
    public void Parse_TitleFallsBackToTextThenToTheUrl()
    {
        var feeds = OpmlParser.Parse(Opml("""
            <outline type="rss" text="From text" xmlUrl="https://a.example/feed" />
            <outline type="rss" xmlUrl="https://b.example/feed" />
            """));

        Assert.Equal("From text", feeds[0].Title);
        Assert.Equal("https://b.example/feed", feeds[1].Title);
    }

    [Fact]
    public void Parse_EmptyBody_ReturnsNoFeeds()
    {
        Assert.Empty(OpmlParser.Parse(Opml("")));
    }

    [Fact]
    public void Parse_MalformedXml_ThrowsFormatException()
    {
        var ex = Assert.Throws<FormatException>(() => OpmlParser.Parse("<opml><body><outline "));
        Assert.Contains("well-formed", ex.Message);
    }

    [Fact]
    public void Parse_NoBodyElement_ThrowsFormatException()
    {
        Assert.Throws<FormatException>(() => OpmlParser.Parse("""<opml version="2.0"><head/></opml>"""));
    }

    [Fact]
    public void Parse_DocumentOverSizeLimit_ThrowsFormatException()
    {
        var huge = new string('x', OpmlParser.MaxDocumentBytes + 1);
        Assert.Throws<FormatException>(() => OpmlParser.Parse(huge));
    }

    [Fact]
    public void Parse_MoreFeedsThanTheCap_ThrowsFormatException()
    {
        var body = string.Join('\n', Enumerable.Range(0, OpmlParser.MaxFeeds + 1)
            .Select(i => $"""<outline type="rss" xmlUrl="https://example.com/feed/{i}" />"""));

        Assert.Throws<FormatException>(() => OpmlParser.Parse(Opml(body)));
    }

    [Fact]
    public void Parse_PathologicallyDeepNesting_ThrowsFormatExceptionInsteadOfOverflowing()
    {
        var body = string.Concat(Enumerable.Repeat("<outline text=\"f\">", 200))
            + "<outline type=\"rss\" xmlUrl=\"https://a.example/feed\" />"
            + string.Concat(Enumerable.Repeat("</outline>", 200));

        Assert.Throws<FormatException>(() => OpmlParser.Parse(Opml(body)));
    }

    [Fact]
    public void Parse_DoctypeDeclaration_ThrowsFormatExceptionNotXxe()
    {
        var withDoctype = """
            <?xml version="1.0"?>
            <!DOCTYPE opml [ <!ENTITY x "expanded"> ]>
            <opml version="2.0"><body><outline type="rss" xmlUrl="https://a.example/feed" /></body></opml>
            """;

        Assert.Throws<FormatException>(() => OpmlParser.Parse(withDoctype));
    }
}
