using Kuulla.Api.Services;

namespace Kuulla.Api.Tests;

public class TranscriptParsingTests
{
    [Theory]
    [InlineData("application/json", "{}", TranscriptFormat.Json)]
    [InlineData("application/json; charset=utf-8", "{}", TranscriptFormat.Json)]
    [InlineData("text/vtt", "WEBVTT", TranscriptFormat.Vtt)]
    [InlineData("application/x-subrip", "1\n00:00:00,000 --> 00:00:01,000\nhi", TranscriptFormat.Srt)]
    [InlineData("application/srt", "x", TranscriptFormat.Srt)]
    public void DetectFormat_UsesDeclaredMimeType(string mime, string body, TranscriptFormat expected)
    {
        Assert.Equal(expected, TranscriptParsing.DetectFormat(mime, body));
    }

    [Theory]
    [InlineData("WEBVTT\n\n00:00.000 --> 00:01.000\nhi", TranscriptFormat.Vtt)]
    [InlineData("﻿  {\n\"segments\": []}", TranscriptFormat.Json)]
    [InlineData("[ { } ]", TranscriptFormat.Json)]
    [InlineData("1\n00:00:00,000 --> 00:00:01,000\nhi", TranscriptFormat.Srt)]
    [InlineData("just some prose", TranscriptFormat.Unknown)]
    public void DetectFormat_SniffsContentWhenMimeTypeUnhelpful(string body, TranscriptFormat expected)
    {
        Assert.Equal(expected, TranscriptParsing.DetectFormat(null, body));
        Assert.Equal(expected, TranscriptParsing.DetectFormat("application/octet-stream", body));
    }

    [Fact]
    public void ParseJson_ReadsWrappedSegmentsDocument()
    {
        const string json = """
            {
              "version": "1.0.0",
              "segments": [
                { "startTime": 0.0, "endTime": 2.5, "body": "Hello there." },
                { "startTime": 2.5, "endTime": 5.0, "body": "  General Kenobi.  " }
              ]
            }
            """;

        var segments = TranscriptParsing.Parse(TranscriptFormat.Json, json);

        Assert.Equal(2, segments.Count);
        Assert.Equal(TimeSpan.Zero, segments[0].StartTime);
        Assert.Equal(TimeSpan.FromSeconds(2.5), segments[0].EndTime);
        Assert.Equal("Hello there.", segments[0].Text);
        Assert.Equal("General Kenobi.", segments[1].Text);
    }

    [Fact]
    public void ParseJson_AcceptsBareArrayAndStartEndTextAliases()
    {
        const string json = """
            [
              { "start": 1, "end": 2, "text": "one" },
              { "start": 2, "text": "two, no end" }
            ]
            """;

        var segments = TranscriptParsing.Parse(TranscriptFormat.Json, json);

        Assert.Equal(2, segments.Count);
        Assert.Equal(TimeSpan.FromSeconds(1), segments[0].StartTime);
        Assert.Equal(TimeSpan.FromSeconds(2), segments[0].EndTime);
        Assert.Null(segments[1].EndTime);
        Assert.Equal("two, no end", segments[1].Text);
    }

    [Fact]
    public void ParseJson_SkipsEntriesWithNoStartOrNoTextAndIgnoresBadEnd()
    {
        const string json = """
            {
              "segments": [
                { "startTime": 0, "body": "kept" },
                { "body": "no start" },
                { "startTime": 5 },
                { "startTime": 6, "body": "   " },
                { "startTime": 7, "endTime": 3, "body": "end before start" },
                { "startTime": "nope", "body": "non-numeric start" }
              ]
            }
            """;

        var segments = TranscriptParsing.Parse(TranscriptFormat.Json, json);

        Assert.Equal(2, segments.Count);
        Assert.Equal("kept", segments[0].Text);
        Assert.Equal("end before start", segments[1].Text);
        Assert.Null(segments[1].EndTime);
    }

    [Fact]
    public void ParseJson_ReturnsEmptyForInvalidJson()
    {
        Assert.Empty(TranscriptParsing.Parse(TranscriptFormat.Json, "not json"));
    }

    [Fact]
    public void ParseSrt_ReadsNumberedCuesWithMultilineText()
    {
        const string srt = """
            1
            00:00:01,000 --> 00:00:04,000
            First line
            still first cue

            2
            00:01:02,500 --> 00:01:05,000
            Second cue
            """;

        var segments = TranscriptParsing.Parse(TranscriptFormat.Srt, srt);

        Assert.Equal(2, segments.Count);
        Assert.Equal(TimeSpan.FromSeconds(1), segments[0].StartTime);
        Assert.Equal(TimeSpan.FromSeconds(4), segments[0].EndTime);
        Assert.Equal("First line\nstill first cue", segments[0].Text);
        Assert.Equal(new TimeSpan(0, 0, 1, 2, 500), segments[1].StartTime);
    }

    [Fact]
    public void ParseVtt_SkipsHeaderAndNoteBlocksAndCueSettingsAndTags()
    {
        const string vtt = """
            WEBVTT - Some title

            NOTE this is a comment
            spanning content

            intro
            00:00:00.000 --> 00:00:02.000 align:start position:0%
            <v Host>Welcome <b>back</b>

            00:01:00.000 --> 00:01:03.500
            Second cue
            """;

        var segments = TranscriptParsing.Parse(TranscriptFormat.Vtt, vtt);

        Assert.Equal(2, segments.Count);
        Assert.Equal(TimeSpan.Zero, segments[0].StartTime);
        Assert.Equal(TimeSpan.FromSeconds(2), segments[0].EndTime);
        Assert.Equal("Welcome back", segments[0].Text);
        Assert.Equal(TimeSpan.FromMinutes(1), segments[1].StartTime);
        Assert.Equal("Second cue", segments[1].Text);
    }

    [Fact]
    public void ParseVtt_AcceptsShortMmSsTimecodes()
    {
        const string vtt = """
            WEBVTT

            00:01.000 --> 00:03.000
            short form
            """;

        var segment = Assert.Single(TranscriptParsing.Parse(TranscriptFormat.Vtt, vtt));
        Assert.Equal(TimeSpan.FromSeconds(1), segment.StartTime);
        Assert.Equal(TimeSpan.FromSeconds(3), segment.EndTime);
    }

    [Fact]
    public void Parse_ReturnsEmptyForUnknownFormat()
    {
        Assert.Empty(TranscriptParsing.Parse(TranscriptFormat.Unknown, "anything"));
    }

    [Fact]
    public void ParseSubtitles_SkipsCueWithOverflowingHoursInsteadOfThrowing()
    {
        // 999999999 hours parses as an int but overflows the TimeSpan constructor.
        const string srt = """
            1
            999999999:00:00,000 --> 999999999:00:05,000
            overflow

            2
            00:00:10,000 --> 00:00:12,000
            fine
            """;

        var segment = Assert.Single(TranscriptParsing.Parse(TranscriptFormat.Srt, srt));
        Assert.Equal("fine", segment.Text);
    }
}
