using System.Reflection;
using System.Text.Json;
using SteamKit2.Internal;
using WorkshopBridge;

internal static class ExplorerTests
{
    private static readonly string[] Genres = ["", "Abstract", "Animal", "Anime", "Fantasy", "Game", "Landscape", "Music", "Nature", "Sci-Fi", "Technology"];
    private static readonly (string Input, string Tag)[] Kinds = [("all", null), ("video", "Video"), ("web", "Web"), ("scene", "Scene"), ("application", "Application")];

    public static void Run(TextWriter report)
    {
        var tests = new (string Name, Action Run)[]
        {
            ("omitted options and empty query browse seven-day popularity", Defaults),
            ("every sort keeps text search and uses the documented query type", Sorts),
            ("all 165 sort-kind-genre combinations require both exact tags", Filters),
            ("invalid option values and JSON types return invalidRequest", InvalidOptions),
            ("invalid queries and pages return invalidRequest", InvalidQueryAndPage),
            ("metadata preserves creator ID and original tags without invented fields", Metadata),
            ("search events retain metadata, total and page size after filtering", SearchEvents),
        };
        foreach (var test in tests)
        {
            try { test.Run(); }
            catch (Exception error) { throw new Exception(test.Name + ": " + error.Message, error); }
            report.WriteLine("PASS " + test.Name);
        }
        report.WriteLine($"PASS {tests.Length} explorer tests");
    }

    private static CPublishedFile_QueryFiles_Request Build(object request) => HelperProgram.BuildSearchRequest(JsonSerializer.SerializeToElement(request));

    private static void Equal<T>(T expected, T actual, string field)
    {
        if (!EqualityComparer<T>.Default.Equals(expected, actual)) throw new Exception($"{field}: expected {expected}; got {actual}");
    }

    private static void Defaults()
    {
        var request = Build(new { query = "", page = 1 });
        Equal(3u, request.query_type, "query_type");
        Equal(7u, request.days, "days");
        Equal("", request.search_text, "search_text");
        Equal(431960u, request.appid, "appid");
        Equal(1u, request.page, "page");
        Equal(30u, request.numperpage, "numperpage");
        Equal(0, request.requiredtags.Count, "requiredtags");
        Equal(true, request.match_all_tags, "match_all_tags");
        Equal(true, request.return_tags, "return_tags");
        Equal(true, request.return_previews, "return_previews");
        Equal(true, request.return_short_description, "return_short_description");
    }

    private static void Sorts()
    {
        foreach (var (sort, type) in new[] { ("popular", 3u), ("recent", 1u), ("rated", 0u) })
        foreach (var query in new[] { "", "  별빛 & ocean  ", new string('a', 512) })
        {
            var request = Build(new { query, page = 4, sort });
            Equal(type, request.query_type, sort + " query_type");
            Equal(query, request.search_text, sort + " search_text");
            Equal(sort == "popular", request.ShouldSerializedays(), sort + " days presence");
            if (sort == "popular") Equal(7u, request.days, sort + " days");
            Equal(4u, request.page, sort + " page");
            Equal(30u, request.numperpage, sort + " numperpage");
            // Test the same protobuf fields that the normal SteamKit client sends.
            using var bytes = new MemoryStream();
            ProtoBuf.Serializer.Serialize(bytes, request);
            bytes.Position = 0;
            var wire = ProtoBuf.Serializer.Deserialize<CPublishedFile_QueryFiles_Request>(bytes);
            Equal(type, wire.query_type, sort + " wire query_type");
            Equal(query, wire.search_text, sort + " wire search_text");
        }
    }

    private static void Filters()
    {
        foreach (var sort in new[] { "popular", "recent", "rated" })
        foreach (var (kind, tag) in Kinds)
        foreach (var genre in Genres)
        {
            var request = Build(new { query = "", page = 2, sort, kind, genre });
            var expected = new[] { tag, genre }.Where(value => !string.IsNullOrEmpty(value));
            Equal(string.Join(',', expected), string.Join(',', request.requiredtags), $"{sort}/{kind}/{genre} tags");
            Equal(true, request.match_all_tags, "combined tags use AND");
            Equal(true, request.return_tags, "return_tags");
            using var bytes = new MemoryStream();
            ProtoBuf.Serializer.Serialize(bytes, request);
            bytes.Position = 0;
            var wire = ProtoBuf.Serializer.Deserialize<CPublishedFile_QueryFiles_Request>(bytes);
            Equal(string.Join(',', expected), string.Join(',', wire.requiredtags), "wire requiredtags");
            Equal(true, wire.match_all_tags, "wire match_all_tags");
        }
        Equal("Anime", string.Join(',', Build(new { query = "", page = 1, genre = "Anime" }).requiredtags), "genre without kind");
        Equal("Video", string.Join(',', Build(new { query = "", page = 1, kind = "video" }).requiredtags), "kind without genre");
    }

    private static void Reject(object request)
    {
        try { Build(request); }
        catch (HelperFailure error) { Equal("invalidRequest", error.Code, JsonSerializer.Serialize(request)); return; }
        throw new Exception("Expected invalidRequest for " + JsonSerializer.Serialize(request));
    }

    private static void InvalidOptions()
    {
        foreach (var key in new[] { "sort", "kind", "genre" })
        foreach (var value in new object[] { null, 1, true, new[] { "popular" }, new { value = "popular" }, "unknown", " ", "POPULAR", "Video", "anime", "Sci-fi", " Anime " })
            Reject(new Dictionary<string, object> { ["query"] = "", ["page"] = 1, [key] = value });
        Reject(new { query = "", page = 1, sort = "" });
        Reject(new { query = "", page = 1, kind = "" });
    }

    private static void InvalidQueryAndPage()
    {
        foreach (var query in new object[] { null, 1, true, new[] { "query" }, new string('a', 513) }) Reject(new { query, page = 1 });
        foreach (var page in new object[] { null, "1", true, 0, -1, 1.5, 2147483648L, new[] { 1 } }) Reject(new { query = "", page });
        Reject(new { page = 1 });
        Reject(new { query = "" });
    }

    private static PublishedFileDetails Details()
    {
        var details = new PublishedFileDetails
        {
            result = 1, consumer_appid = 431960, publishedfileid = 123,
            title = "Fixture", creator = 76561198000000123UL,
            file_description = "Original description", preview_url = "https://example.invalid/preview.jpg", file_size = 9,
        };
        foreach (var tag in new[] { "Video", "Sci-Fi", "Custom creator tag" }) details.tags.Add(new PublishedFileDetails.Tag { tag = tag });
        return details;
    }

    private static void Metadata()
    {
        var details = Details();
        var item = JsonSerializer.SerializeToElement(WorkshopItem.From(details));
        Equal("76561198000000123", item.GetProperty("creatorID").GetString(), "creatorID");
        Equal("Video,Sci-Fi,Custom creator tag", string.Join(',', item.GetProperty("tags").EnumerateArray().Select(tag => tag.GetString())), "tags");
        Equal("video", item.GetProperty("kind").GetString(), "kind");
        Equal("Original description", item.GetProperty("description").GetString(), "description");
        Equal("creatorID,description,id,kind,previewURL,size,tags,title", string.Join(',', item.EnumerateObject().Select(p => p.Name).Order()), "only supported metadata fields");
        details.Resetcreator();
        details.tags.Clear();
        item = JsonSerializer.SerializeToElement(WorkshopItem.From(details));
        Equal(JsonValueKind.Null, item.GetProperty("creatorID").ValueKind, "missing creatorID");
        Equal(0, item.GetProperty("tags").GetArrayLength(), "missing tags");
        details.creator = 0;
        item = JsonSerializer.SerializeToElement(WorkshopItem.From(details));
        Equal(JsonValueKind.Null, item.GetProperty("creatorID").ValueKind, "zero creator is not an account");
    }

    private static void SearchEvents()
    {
        var outputField = typeof(HelperProgram).GetField("output", BindingFlags.NonPublic | BindingFlags.Static)!;
        var previous = outputField.GetValue(null);
        using var output = new StringWriter();
        outputField.SetValue(null, output);
        try
        {
            var response = new CPublishedFile_QueryFiles_Response { total = 65 };
            response.publishedfiledetails.Add(Details());
            response.publishedfiledetails.Add(new PublishedFileDetails { result = 1, consumer_appid = 1 });
            response.publishedfiledetails.Add(new PublishedFileDetails { result = 1, consumer_appid = 431960, file_type = 2 });
            response.publishedfiledetails.Add(new PublishedFileDetails { result = 9, consumer_appid = 431960 });
            foreach (var page in new[] { 1, 3 })
            {
                output.GetStringBuilder().Clear();
                HelperProgram.EmitSearchResults("fixture", response, page);
                using var document = JsonDocument.Parse(output.ToString());
                var message = document.RootElement;
                Equal("items", message.GetProperty("type").GetString(), "type");
                Equal(65, message.GetProperty("total").GetInt32(), "total");
                Equal(page, message.GetProperty("page").GetInt32(), "page");
                Equal(30, message.GetProperty("pageSize").GetInt32(), "pageSize");
                Equal(1, message.GetProperty("items").GetArrayLength(), "filtered items");
                Equal("76561198000000123", message.GetProperty("items")[0].GetProperty("creatorID").GetString(), "event creatorID");
                Equal(3, message.GetProperty("items")[0].GetProperty("tags").GetArrayLength(), "event tags");
            }
        }
        finally { outputField.SetValue(null, previous); }
    }
}
