using System.Globalization;
using System.Text.Json;
using System.Text.RegularExpressions;
using Kuulla.Api.Models;

namespace Kuulla.Api.Services;

public enum TranscriptFormat
{
    Unknown,
    Json,
    Srt,
    Vtt,
}

// Pure, side-effect-free normalization of the three transcript source formats into
// TranscriptSegment lists. Kept separate from TranscriptService (which does the fetching) so
// the format handling is unit-testable without any HTTP.
public static partial class TranscriptParsing
{
    // Splits on a blank line (optionally containing whitespace), tolerating both \n and \r\n.
    [GeneratedRegex(@"\r?\n[ \t]*\r?\n")]
    private static partial Regex BlockSeparator();

    // "-->" with optional surrounding whitespace; used to find the timing line within a cue block.
    [GeneratedRegex(@"\s*-->\s*")]
    private static partial Regex CueArrow();

    // A leading SRT sequence number line.
    [GeneratedRegex(@"^\d+$")]
    private static partial Regex SrtIndexLine();

    // Inline VTT markup: voice/class spans (<v Bob>), timestamps (<00:00:01.000>), etc.
    [GeneratedRegex(@"<[^>]+>")]
    private static partial Regex VttInlineTag();

    public static TranscriptFormat DetectFormat(string? mimeType, string content)
    {
        var type = mimeType?.Split(';', 2)[0].Trim().ToLowerInvariant();
        switch (type)
        {
            case "application/json" or "text/json" or "application/x-json":
                return TranscriptFormat.Json;
            case "text/vtt":
                return TranscriptFormat.Vtt;
            case "application/x-subrip" or "application/srt" or "text/srt":
                return TranscriptFormat.Srt;
        }

        if (type is not null && type.Contains("json"))
        {
            return TranscriptFormat.Json;
        }

        var trimmed = content.TrimStart('﻿', ' ', '\t', '\r', '\n');
        if (trimmed.StartsWith("WEBVTT", StringComparison.Ordinal))
        {
            return TranscriptFormat.Vtt;
        }

        if (trimmed.StartsWith('{') || trimmed.StartsWith('['))
        {
            return TranscriptFormat.Json;
        }

        // "1\n00:00:00,000 --> ..." — an SRT cue with its sequence number.
        if (Regex.IsMatch(trimmed, @"^\d+\s*\r?\n\d{1,2}:\d{2}:\d{2},\d{3}\s*-->", RegexOptions.CultureInvariant))
        {
            return TranscriptFormat.Srt;
        }

        return TranscriptFormat.Unknown;
    }

    public static IReadOnlyList<TranscriptSegment> Parse(TranscriptFormat format, string content) => format switch
    {
        TranscriptFormat.Json => ParseJson(content),
        TranscriptFormat.Srt => ParseSubtitles(content, srt: true),
        TranscriptFormat.Vtt => ParseSubtitles(content, srt: false),
        _ => [],
    };

    // JSON Podcast Transcript (https://github.com/Podcastindex-org/podcast-namespace/blob/main/transcripts/transcripts.md):
    // { "version": "1.0.0", "segments": [ { "startTime": 0.0, "endTime": 2.5, "body": "..." } ] }.
    // Also accepts a bare top-level array, and "start"/"end"/"text" as aliases for the canonical
    // key names. A segment with no finite start time or no text is skipped rather than failing the
    // whole document.
    private static IReadOnlyList<TranscriptSegment> ParseJson(string content)
    {
        JsonDocument document;
        try
        {
            // A leading UTF-8 BOM is an invalid first character for JsonDocument.Parse(string).
            document = JsonDocument.Parse(content.TrimStart('﻿'));
        }
        catch (JsonException)
        {
            return [];
        }

        using (document)
        {
            var root = document.RootElement;
            JsonElement segmentsElement;
            if (root.ValueKind == JsonValueKind.Array)
            {
                segmentsElement = root;
            }
            else if (root.ValueKind == JsonValueKind.Object && root.TryGetProperty("segments", out var nested)
                     && nested.ValueKind == JsonValueKind.Array)
            {
                segmentsElement = nested;
            }
            else
            {
                return [];
            }

            var segments = new List<TranscriptSegment>();
            foreach (var element in segmentsElement.EnumerateArray())
            {
                if (element.ValueKind != JsonValueKind.Object)
                {
                    continue;
                }

                if (!TryGetSeconds(element, "startTime", "start", out var start))
                {
                    continue;
                }

                var text = GetString(element, "body", "text")?.Trim();
                if (string.IsNullOrEmpty(text))
                {
                    continue;
                }

                TimeSpan? end = TryGetSeconds(element, "endTime", "end", out var endValue) && endValue >= start
                    ? endValue
                    : null;

                segments.Add(new TranscriptSegment(start, end, text));
            }

            return segments;
        }
    }

    private static bool TryGetSeconds(JsonElement element, string primary, string alias, out TimeSpan value)
    {
        value = default;
        if (!element.TryGetProperty(primary, out var raw) && !element.TryGetProperty(alias, out raw))
        {
            return false;
        }

        if (raw.ValueKind != JsonValueKind.Number || !raw.TryGetDouble(out var seconds)
            || !double.IsFinite(seconds) || seconds < 0 || seconds > TimeSpan.MaxValue.TotalSeconds)
        {
            return false;
        }

        value = TimeSpan.FromSeconds(seconds);
        return true;
    }

    private static string? GetString(JsonElement element, string primary, string alias)
    {
        if (element.TryGetProperty(primary, out var raw) && raw.ValueKind == JsonValueKind.String)
        {
            return raw.GetString();
        }

        return element.TryGetProperty(alias, out raw) && raw.ValueKind == JsonValueKind.String
            ? raw.GetString()
            : null;
    }

    // SRT and WebVTT are close enough to share one block-oriented parser: split into cue blocks on
    // blank lines, find the "start --> end" line in each (SRT precedes it with a sequence number;
    // VTT may precede it with a cue identifier and follow the end time with cue settings), and
    // join the remaining lines as the cue text. VTT NOTE/STYLE/REGION blocks and the WEBVTT
    // header are skipped. Malformed blocks are dropped individually.
    private static IReadOnlyList<TranscriptSegment> ParseSubtitles(string content, bool srt)
    {
        var normalized = content.TrimStart('﻿');
        var blocks = BlockSeparator().Split(normalized);
        var segments = new List<TranscriptSegment>();

        foreach (var block in blocks)
        {
            var trimmedBlock = block.Trim('\r', '\n');
            if (trimmedBlock.Length == 0)
            {
                continue;
            }

            var lines = trimmedBlock.Split('\n').Select(l => l.TrimEnd('\r')).ToArray();
            var firstLine = lines[0].Trim();

            if (!srt && (firstLine.StartsWith("WEBVTT", StringComparison.Ordinal)
                         || firstLine is "NOTE" || firstLine.StartsWith("NOTE ", StringComparison.Ordinal)
                         || firstLine is "STYLE" or "REGION"))
            {
                continue;
            }

            var timingIndex = Array.FindIndex(lines, l => l.Contains("-->", StringComparison.Ordinal));
            if (timingIndex < 0)
            {
                continue;
            }

            if (srt && timingIndex > 0 && !SrtIndexLine().IsMatch(lines[timingIndex - 1].Trim()))
            {
                // A stray line before the timing line that isn't a sequence number — treat the
                // block as malformed rather than guessing.
                continue;
            }

            var arrowParts = CueArrow().Split(lines[timingIndex].Trim());
            if (arrowParts.Length < 2)
            {
                continue;
            }

            var startToken = arrowParts[0].Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).LastOrDefault();
            var endToken = arrowParts[1].Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).FirstOrDefault();
            if (!TryParseTimecode(startToken, out var start))
            {
                continue;
            }

            TimeSpan? end = TryParseTimecode(endToken, out var endValue) && endValue >= start ? endValue : null;

            var textLines = lines.Skip(timingIndex + 1);
            var text = string.Join('\n', textLines).Trim();
            if (!srt)
            {
                text = VttInlineTag().Replace(text, string.Empty).Trim();
            }

            if (text.Length == 0)
            {
                continue;
            }

            segments.Add(new TranscriptSegment(start, end, text));
        }

        return segments;
    }

    // "HH:MM:SS,mmm" / "HH:MM:SS.mmm" / "MM:SS.mmm" — SRT uses a comma before the milliseconds,
    // VTT a dot, and VTT allows the hours component to be omitted. Milliseconds are optional.
    private static bool TryParseTimecode(string? token, out TimeSpan value)
    {
        value = default;
        if (string.IsNullOrWhiteSpace(token))
        {
            return false;
        }

        var normalized = token.Trim().Replace(',', '.');
        var dotIndex = normalized.IndexOf('.');
        var millisecondsPart = dotIndex >= 0 ? normalized[(dotIndex + 1)..] : null;
        var clockPart = dotIndex >= 0 ? normalized[..dotIndex] : normalized;

        var pieces = clockPart.Split(':');
        if (pieces.Length is < 2 or > 3)
        {
            return false;
        }

        int hours = 0, minutes, seconds;
        if (pieces.Length == 3)
        {
            if (!int.TryParse(pieces[0], NumberStyles.None, CultureInfo.InvariantCulture, out hours))
            {
                return false;
            }
        }

        if (!int.TryParse(pieces[^2], NumberStyles.None, CultureInfo.InvariantCulture, out minutes)
            || !int.TryParse(pieces[^1], NumberStyles.None, CultureInfo.InvariantCulture, out seconds)
            || minutes > 59 || seconds > 59)
        {
            return false;
        }

        var milliseconds = 0;
        if (!string.IsNullOrEmpty(millisecondsPart))
        {
            // Pad/truncate to exactly 3 digits so ".5" reads as 500ms, not 5ms.
            var normalizedMs = (millisecondsPart + "000")[..3];
            if (!int.TryParse(normalizedMs, NumberStyles.None, CultureInfo.InvariantCulture, out milliseconds))
            {
                return false;
            }
        }

        try
        {
            // A huge hours component (transcript content is untrusted) overflows the TimeSpan
            // constructor — treat that as an unparseable cue, not a 500.
            value = new TimeSpan(0, hours, minutes, seconds, milliseconds);
            return true;
        }
        catch (ArgumentOutOfRangeException)
        {
            return false;
        }
    }
}
