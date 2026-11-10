using System.Text.Json;
using SteamKit2.Internal;

namespace WorkshopBridge;

internal static class WorkshopSearchFilters
{
    private const int MaxGroups = 16;
    private const int MaxTagLength = 64;

    // Exact tag names from https://steamcommunity.com/workshop/browse/?appid=431960&l=english.
    private static readonly HashSet<string> Genres = new(StringComparer.Ordinal)
    {
        "Abstract", "Animal", "Anime", "Cartoon", "CGI", "Cyberpunk", "Fantasy", "Game", "Girls", "Guys",
        "Landscape", "Medieval", "Memes", "MMD", "Music", "Nature", "Pixel art", "Relaxing", "Retro",
        "Sci-Fi", "Sports", "Technology", "Television", "Vehicle", "Unspecified",
    };

    private static readonly HashSet<string> AllowedTags = new(Genres.Concat(new[]
    {
        "Approved", "Audio responsive", "3D", "Customizable", "Puppet Warp", "HDR", "Media Integration",
        "User Shortcut", "Video Texture", "Asset Pack",
        "Scene", "Video", "Application", "Web", "Everyone", "Questionable", "Mature",
        "Standard Definition", "1280 x 720", "1366 x 768", "1920 x 1080", "2560 x 1440", "3840 x 2160",
        "Ultrawide Standard Definition", "Ultrawide 2560 x 1080", "Ultrawide 3440 x 1440",
        "Dual Standard Definition", "Dual 3840 x 1080", "Dual 5120 x 1440", "Dual 7680 x 2160",
        "Triple Standard Definition", "Triple 4096 x 768", "Triple 5760 x 1080", "Triple 7680 x 1440", "Triple 11520 x 2160",
        "Portrait Standard Definition", "Portrait 720 x 1280", "Portrait 1080 x 1920", "Portrait 1440 x 2560", "Portrait 2160 x 3840",
        "Other resolution", "Dynamic resolution",
    }), StringComparer.Ordinal);

    internal static bool IsGenre(string genre) => Genres.Contains(genre);

    internal static void Apply(JsonElement request, CPublishedFile_QueryFiles_Request search)
    {
        if (request.TryGetProperty("tagGroups", out var groups))
        {
            if (groups.ValueKind != JsonValueKind.Array || groups.GetArrayLength() > MaxGroups)
                throw new HelperFailure("invalidRequest");
            foreach (var group in groups.EnumerateArray())
            {
                var tags = ReadTags(group);
                if (tags.Length == 0) throw new HelperFailure("invalidRequest");
                var tagGroup = new CPublishedFile_QueryFiles_Request.TagGroup();
                tagGroup.tags.AddRange(tags);
                search.taggroups.Add(tagGroup);
            }
        }
        else
        {
            var everyone = new CPublishedFile_QueryFiles_Request.TagGroup();
            everyone.tags.Add("Everyone");
            search.taggroups.Add(everyone);
            search.excludedtags.AddRange(["Questionable", "Mature"]);
        }

        if (request.TryGetProperty("excludedTags", out var exclusions))
        {
            foreach (var tag in ReadTags(exclusions))
                if (!search.excludedtags.Contains(tag)) search.excludedtags.Add(tag);
        }

        // A partially excluded OR group still has valid alternatives; an exhausted group cannot match.
        if (search.requiredtags.Any(search.excludedtags.Contains) ||
            search.taggroups.Any(group => group.tags.All(search.excludedtags.Contains)))
            throw new HelperFailure("invalidRequest");
    }

    private static string[] ReadTags(JsonElement value)
    {
        if (value.ValueKind != JsonValueKind.Array || value.GetArrayLength() > AllowedTags.Count)
            throw new HelperFailure("invalidRequest");
        var tags = new List<string>();
        foreach (var element in value.EnumerateArray())
        {
            if (element.ValueKind != JsonValueKind.String) throw new HelperFailure("invalidRequest");
            var tag = element.GetString();
            if (tag.Length > MaxTagLength || !AllowedTags.Contains(tag)) throw new HelperFailure("invalidRequest");
            if (!tags.Contains(tag)) tags.Add(tag);
        }
        return tags.ToArray();
    }
}
