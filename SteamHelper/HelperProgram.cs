using System.Text.Json;
using DepotDownloader;
using SteamKit2;

[assembly: System.Runtime.CompilerServices.InternalsVisibleTo("SteamHelper.Tests")]

namespace WorkshopBridge;

internal static class HelperProgram
{
    private static readonly object outputLock = new();
    private static TextWriter output;
    private static volatile string activeID;
    private static Task active;
    private static HelperFailure storageError;

    public static async Task<int> Main(string[] args)
    {
        var input = Console.In;
        output = Console.Out;
        Console.SetOut(TextWriter.Null);
        Console.SetError(TextWriter.Null);
        Console.SetIn(TextReader.Null);
        DebugLog.Enabled = false;
        if (args.Length != 2 || args[0] != "--data-directory") return 2;
        try { AccountSettingsStore.LoadFromFile(args[1]); }
        catch (HelperFailure error) { storageError = error; }
        ContentDownloader.Config = new DownloadConfig { RememberPassword = true, MaxDownloads = 4, VerifyAll = true };
        while (await input.ReadLineAsync() is { } line)
        {
            string id = "";
            try
            {
                if (line.Length > 1024 * 1024) throw new HelperFailure("invalidRequest");
                using var document = JsonDocument.Parse(line);
                var request = document.RootElement;
                id = Text(request, "id");
                if (!Guid.TryParse(id, out _)) throw new HelperFailure("invalidRequest");
                var command = Text(request, "command");
                if (command == "guard")
                {
                    if (activeID != id) Error(id, "invalidRequest");
                    else if (!BridgeContext.SupplyGuard(Text(request, "code"))) ContentDownloader.ShutdownSteam3();
                    continue;
                }
                if (activeID != null) { Error(id, "busy"); continue; }
                activeID = id;
                var copy = request.Clone();
                BridgeContext.Emit = (type, fields) => Emit(id, type, fields);
                active = Task.Run(() => Run(id, command, copy));
            }
            catch { Error(Guid.TryParse(id, out _) ? id : "", "invalidRequest"); }
        }
        BridgeContext.CancelGuard();
        ContentDownloader.ShutdownSteam3();
        return 0;
    }

    private static string Text(JsonElement request, string key)
    {
        if (!request.TryGetProperty(key, out var value) || value.ValueKind != JsonValueKind.String) throw new HelperFailure("invalidRequest");
        return value.GetString();
    }

    private static string OptionalText(JsonElement request, string key, string fallback) =>
        request.TryGetProperty(key, out _) ? Text(request, key) : fallback;

    private static async Task Run(string id, string command, JsonElement request)
    {
        try
        {
            if (storageError != null) throw storageError;
            switch (command)
            {
                case "loginQR":
                case "loginPassword":
                case "resume":
                    ContentDownloader.ShutdownSteam3();
                    BridgeContext.AuthenticationError = null;
                    ContentDownloader.Config.UseQrCode = command == "loginQR";
                    var username = command == "resume" ? AccountSettingsStore.Instance.SavedUsername : command == "loginPassword" ? Text(request, "username") : null;
                    var password = command == "loginPassword" ? Text(request, "password") : null;
                    if (command == "resume" && username == null) throw new HelperFailure("credentialsUnavailable");
                    if (command == "loginPassword")
                    {
                        if (string.IsNullOrWhiteSpace(username) || string.IsNullOrEmpty(password)) throw new HelperFailure("invalidRequest");
                        AccountSettingsStore.Instance.LoginTokens.Clear();
                    }
                    if (!ContentDownloader.InitializeSteam3(username, password))
                        throw BridgeContext.AuthenticationError ?? new HelperFailure(command == "resume" ? "credentialsUnavailable" : "authenticationFailed");
                    Emit(id, "authenticated", new { account = ContentDownloader.Session.AccountName });
                    break;
                case "search":
                    RequireLogin();
                    var searchRequest = BuildSearchRequest(request);
                    var results = await ContentDownloader.Session.Search(searchRequest);
                    RequireLogin();
                    EmitSearchResults(id, results, (int)searchRequest.page);
                    break;
                case "details":
                case "download":
                    RequireLogin();
                    var itemID = Text(request, "itemID");
                    if (!ulong.TryParse(itemID, out var numericID) || numericID == 0) throw new HelperFailure("invalidRequest");
                    var details = await ContentDownloader.Session.GetPublishedFileDetails(431960, numericID);
                    WorkshopItem.Validate(details);
                    if (command == "details")
                    {
                        RequireLogin();
                        Emit(id, "detail", new { item = WorkshopItem.From(details) });
                        break;
                    }
                    var directory = Text(request, "directory");
                    try
                    {
                        using var boundary = new SafeDirectory(directory);
                        if (Directory.EnumerateFileSystemEntries(boundary.Root).Any()) throw new HelperFailure("unsafePath");
                        DownloadIO.Boundary = boundary;
                        ContentDownloader.Config.InstallDirectory = boundary.Root;
                        DepotConfigStore.Instance = null;
                        await ContentDownloader.DownloadPubfileAsync(431960, numericID);
                        boundary.CheckRoot();
                        RequireLogin();
                    }
                    finally { DownloadIO.Boundary = null; }
                    Emit(id, "completed", new { itemID });
                    break;
                default: throw new HelperFailure("invalidRequest");
            }
        }
        catch (HelperFailure error) { Error(id, error.Code); }
        catch (ContentDownloaderException) { Error(id, "downloadFailed"); }
        catch { Error(id, "requestFailed"); }
    }

    internal static SteamKit2.Internal.CPublishedFile_QueryFiles_Request BuildSearchRequest(JsonElement request)
    {
        var query = Text(request, "query");
        if (query.Length > 512 || !request.TryGetProperty("page", out var pageValue) || pageValue.ValueKind != JsonValueKind.Number || !pageValue.TryGetInt32(out var page) || page < 1) throw new HelperFailure("invalidRequest");
        var queryType = OptionalText(request, "sort", "popular") switch
        {
            "popular" => EPublishedFileQueryType.RankedByTrend,
            "recent" => EPublishedFileQueryType.RankedByPublicationDate,
            "rated" => EPublishedFileQueryType.RankedByVote,
            _ => throw new HelperFailure("invalidRequest"),
        };
        var kindTag = OptionalText(request, "kind", "all") switch
        {
            "all" => null,
            "video" => "Video",
            "web" => "Web",
            "scene" => "Scene",
            "application" => "Application",
            _ => throw new HelperFailure("invalidRequest"),
        };
        var genre = OptionalText(request, "genre", "");
        if (genre.Length != 0 && !WorkshopSearchFilters.IsGenre(genre))
            throw new HelperFailure("invalidRequest");
        var search = new SteamKit2.Internal.CPublishedFile_QueryFiles_Request
        {
            appid = 431960, page = (uint)page, numperpage = Steam3Session.SearchPageSize,
            search_text = query, return_previews = true, return_short_description = true,
            query_type = (uint)queryType, match_all_tags = true, return_tags = true,
        };
        if (queryType == EPublishedFileQueryType.RankedByTrend) search.days = 7;
        if (kindTag != null) search.requiredtags.Add(kindTag);
        if (genre.Length != 0) search.requiredtags.Add(genre);
        WorkshopSearchFilters.Apply(request, search);
        return search;
    }

    internal static void EmitSearchResults(string id, SteamKit2.Internal.CPublishedFile_QueryFiles_Response results, int page)
    {
        var items = results.publishedfiledetails.Where(item => item.result == 1 && item.consumer_appid == 431960 && item.file_type != 2).Select(WorkshopItem.From).ToArray();
        Emit(id, "items", new { items, total = results.total, page, pageSize = Steam3Session.SearchPageSize });
    }

    private static void RequireLogin()
    {
        if (ContentDownloader.Session?.IsLoggedOn != true) throw new HelperFailure("authenticationRequired");
    }
    private static void Error(string id, string code) => Emit(id, "error", new { code, message = HelperFailure.MessageFor(code) });
    private static void Emit(string id, string type, object fields)
    {
        var values = JsonSerializer.SerializeToElement(fields).EnumerateObject().ToDictionary(property => property.Name, property => (object)property.Value);
        values["id"] = id;
        values["type"] = type;
        lock (outputLock)
        {
            if (id == activeID && type is "authenticated" or "items" or "detail" or "completed" or "error") activeID = null;
            output.WriteLine(JsonSerializer.Serialize(values));
            output.Flush();
        }
    }
}
