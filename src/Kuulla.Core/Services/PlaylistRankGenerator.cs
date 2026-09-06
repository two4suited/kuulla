using System.Numerics;

namespace Kuulla.Core.Services;

// LexoRank-style midpoint rank strings for PlaylistItem.Order (#104/#105) — see Playlist.cs for
// why: a rank string lets a single reorder/insert touch only the moved item instead of
// renumbering an integer index under concurrent last-write-wins sync from two devices.
//
// Between(before, after) returns a string that sorts (by plain ordinal string comparison) strictly
// between `before` and `after`. Either bound may be null for "no lower/upper bound" (append at the
// start/end of the list). Implemented over base-36 digits so ranks stay compact and human-readable
// in the data explorer; digits are compared as arbitrary-precision integers (via BigInteger) at a
// shared, growing length rather than character-by-character, which sidesteps the usual "does a
// shorter string's implicit padding mean 'lowest possible digit' or 'no constraint'" ambiguity that
// makes naive digit-by-digit midpoint algorithms easy to get subtly wrong.
public static class PlaylistRankGenerator
{
    // Shared with PlaylistService's full-rebuild ordering (ComputeDynamicItemsAsync) and
    // EpisodeService's incremental per-episode insert (EvictOverflowAsync) — both cap an
    // unbounded (MaxEpisodes: null) dynamic playlist at the same size so it can't grow past
    // Cosmos's 2MB item size limit. High enough that no real playlist hits it, low enough to
    // stay comfortably under the document limit.
    public const int UnboundedSafetyCap = 2000;

    private const string Digits = "0123456789abcdefghijklmnopqrstuvwxyz";
    private const int Base = 36;

    public static string Between(string? before, string? after)
    {
        if (before is not null && after is not null && string.CompareOrdinal(before, after) >= 0)
        {
            throw new ArgumentException($"'{before}' must sort before '{after}'.");
        }

        var length = Math.Max(Math.Max(before?.Length ?? 0, after?.Length ?? 0), 1);

        while (true)
        {
            var lowValue = ParseBase36(PadRight(before, length));
            var highValue = after is not null
                ? ParseBase36(PadRight(after, length))
                : BigInteger.Pow(Base, length);

            if (highValue - lowValue > 1)
            {
                var midValue = lowValue + (highValue - lowValue) / 2;
                return FormatBase36(midValue, length);
            }

            length++;
        }
    }

    private static string PadRight(string? value, int length) => (value ?? string.Empty).PadRight(length, '0');

    private static BigInteger ParseBase36(string value)
    {
        var result = BigInteger.Zero;
        foreach (var c in value)
        {
            result = (result * Base) + Digits.IndexOf(c);
        }

        return result;
    }

    private static string FormatBase36(BigInteger value, int length)
    {
        var digits = new char[length];
        for (var i = length - 1; i >= 0; i--)
        {
            digits[i] = Digits[(int)(value % Base)];
            value /= Base;
        }

        return new string(digits);
    }
}
