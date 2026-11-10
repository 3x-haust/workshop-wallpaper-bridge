using SteamKit2;
using SteamKit2.Internal;

namespace WorkshopBridge;

internal sealed record WorkshopItem(string id, string title, string description, string previewURL, string kind, ulong? size, string creatorID, string[] tags)
{
    public static void Validate(PublishedFileDetails details)
    {
        if (details?.result == (uint)EResult.AccessDenied) throw new HelperFailure("accessDenied");
        if (details == null || details.result != (uint)EResult.OK) throw new HelperFailure("unavailable");
        if (details.consumer_appid != 431960) throw new HelperFailure("wrongApp");
        if (details.file_type == 2) throw new HelperFailure("collection");
    }
    public static WorkshopItem From(PublishedFileDetails details)
    {
        Validate(details);
        var kind = details.tags.Select(t => t.tag.ToLowerInvariant()).FirstOrDefault(t => t is "scene" or "video" or "web" or "application");
        var preview = Uri.TryCreate(details.preview_url, UriKind.Absolute, out var uri) && uri.Scheme == "https" ? details.preview_url : null;
        var creatorID = details.ShouldSerializecreator() && details.creator != 0 ? details.creator.ToString() : null;
        return new(details.publishedfileid.ToString(), details.title ?? "", details.file_description ?? details.short_description ?? "", preview, kind, details.file_size, creatorID, details.tags.Select(tag => tag.tag).ToArray());
    }
}
