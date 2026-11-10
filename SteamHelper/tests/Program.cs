using System.Reflection;
using System.Security.Cryptography;
using System.Text.Json;
using DepotDownloader;
using SteamKit2;
using SteamKit2.Internal;
using WorkshopBridge;

internal static class Tests
{
    private static string fixture;
    private static int passed;
    private static readonly BindingFlags HiddenStatic = BindingFlags.NonPublic | BindingFlags.Static;
    private static readonly TextWriter Report = Console.Out;

    public static async Task<int> Main(string[] args)
    {
        if (args.SequenceEqual(new[] { "--cdn-auth" }))
        {
            var report = Report;
            Console.SetOut(TextWriter.Null);
            try { await CDNAuthTests.Run(report); return 0; }
            catch (Exception error) { report.WriteLine("FAIL " + error); return 1; }
            finally { Console.SetOut(report); }
        }
        var resolved = realpath(Path.GetTempPath(), IntPtr.Zero);
        if (resolved == IntPtr.Zero) throw new IOException("Cannot resolve temporary directory");
        try { fixture = Path.Combine(System.Runtime.InteropServices.Marshal.PtrToStringUTF8(resolved)!, "wwb-helper-test-" + Guid.NewGuid()); }
        finally { free(resolved); }
        Directory.CreateDirectory(fixture);
        Console.SetOut(TextWriter.Null);
        try
        {
            await Test("web filenames cannot write outside before HTTP starts", WebPaths);
            await Test("manifest filenames cannot create files outside the root", ManifestPaths);
            await Test("deleted manifest filenames cannot delete outside the root", DeletedPaths);
            await Test("directory, file, dangling symlinks and replaced root are rejected", LinksAndRoot);
            await Test("all root ancestors reject symlinks before writes, creation or permission changes", () => ParentPathTests.Run(fixture));
            await Test("descriptor writes reject hardlinks without truncating their target", Hardlinks);
            await Test("full manifest verification detects missing files, length and hash mismatches", Integrity);
            await Test("missing published manifest returns a typed error", MissingManifest);
            await Test("item contracts distinguish app, collection and unavailable items", Items);
            await Test("private credential JSON is atomic, reloadable and contains only allowed fields", Credentials);
            await Test("credential symlinks and failed saves produce typed storage errors", CredentialFailure);
            await Test("search events preserve the server page size after filtering and on short pages", SearchPagination);
            await Test("overlapping authentication callbacks cannot poll twice or restart after disconnect", Authentication);
            await Test("guard IPC carries only fixed prompts and handles cancellation", Guard);
            await Test("CDN authentication completes every caller on success, rejection and cancellation", () => CDNAuthTests.Run(Report));
            Report.WriteLine($"PASS {passed} tests");
            return 0;
        }
        catch (Exception error) { Report.WriteLine("FAIL " + error); return 1; }
        finally { Console.SetOut(Report); Directory.Delete(fixture, true); }
    }

    private static async Task Test(string name, Func<Task> action)
    {
        await action(); passed++; Report.WriteLine("PASS " + name);
    }
    private static string Folder(string name)
    {
        var path = Path.Combine(fixture, name); Directory.CreateDirectory(path); return path;
    }
    private static void Equal<T>(T expected, T actual)
    {
        if (!EqualityComparer<T>.Default.Equals(expected, actual)) throw new Exception($"Expected {expected}; got {actual}");
    }
    private static void Reject(string code, Action action)
    {
        try { action(); }
        catch (TargetInvocationException e) when (e.InnerException is HelperFailure failure) { Equal(code, failure.Code); return; }
        catch (HelperFailure e) { Equal(code, e.Code); return; }
        throw new Exception("Expected typed failure: " + code);
    }
    private static async Task RejectAsync(string code, Func<Task> action)
    {
        try { await action(); }
        catch (HelperFailure error) { Equal(code, error.Code); return; }
        throw new Exception("Expected typed failure: " + code);
    }
    private static string[] BadNames(string outside) => [outside, "../outside.txt", "nested/../../outside.txt", "", " ", "C:\\outside.txt", "..\\outside.txt", "nested\\..\\outside.txt", "/absolute", "//host/path", "a//b", "a/./b", ".DepotDownloader/depot.config"];

    private static async Task WebPaths()
    {
        var root = Folder("web");
        using var boundary = new SafeDirectory(root); DownloadIO.Boundary = boundary;
        ContentDownloader.Config.InstallDirectory = root;
        var outside = Path.Combine(fixture, "outside.txt");
        var method = typeof(ContentDownloader).GetMethod("DownloadWebFile", HiddenStatic)!;
        foreach (var name in BadNames(outside))
            await RejectAsync("unsafePath", () => (Task)method.Invoke(null, [431960u, name, "invalid:", (ulong?)0])!);
        Equal(false, File.Exists(outside));
    }

    private static DepotManifest.FileData Entry(string name, byte[] bytes) => new(name, [], (EDepotFileFlag)0, (ulong)bytes.Length, SHA1.HashData(bytes), null, false, 0);
    private static object Nested(string name, params object[] args) => Activator.CreateInstance(typeof(ContentDownloader).GetNestedType(name, BindingFlags.NonPublic)!, args)!;
    private static void Field(object instance, string name, object value) => instance.GetType().GetField(name)!.SetValue(instance, value);
    private static object DepotData(string root, List<DepotManifest.FileData> files, DepotManifest previous = null)
    {
        var data = Nested("DepotFilesData");
        Field(data, "depotDownloadInfo", Nested("DepotDownloadInfo", 431960u, 431960u, 1UL, "public", root, Array.Empty<byte>()));
        Field(data, "depotCounter", Nested("DepotDownloadCounter"));
        Field(data, "stagingDir", Path.Combine(root, ".DepotDownloader/staging"));
        Field(data, "filteredFiles", files);
        Field(data, "allFileNames", files.Select(f => f.FileName).ToHashSet());
        Field(data, "previousManifest", previous);
        return data;
    }
    private static Task ManifestPaths()
    {
        var root = Folder("manifest");
        using var boundary = new SafeDirectory(root); DownloadIO.Boundary = boundary;
        var outside = Path.Combine(fixture, "manifest-outside.txt");
        var method = typeof(ContentDownloader).GetMethod("DownloadSteam3AsyncDepotFile", HiddenStatic)!;
        foreach (var name in BadNames(outside).Where(n => !n.StartsWith(".DepotDownloader")))
        {
            var file = Entry(name, []);
            var queue = Activator.CreateInstance(method.GetParameters()[4].ParameterType)!;
            Reject("unsafePath", () => method.Invoke(null, [new CancellationTokenSource(), Nested("GlobalDownloadCounter"), DepotData(root, [file]), file, queue]));
        }
        Equal(false, File.Exists(outside));
        return Task.CompletedTask;
    }
    private static async Task DeletedPaths()
    {
        var root = Folder("deletion");
        using var boundary = new SafeDirectory(root); DownloadIO.Boundary = boundary;
        ContentDownloader.Config.InstallDirectory = root;
        ContentDownloader.Config.MaxDownloads = 1;
        boundary.CreateDirectory(Path.Combine(root, ".DepotDownloader/staging"));
        File.WriteAllBytes(Path.Combine(root, "kept"), []);
        var outside = Path.Combine(fixture, "keep-outside"); File.WriteAllText(outside, "untouched");
        var method = typeof(ContentDownloader).GetMethod("DownloadSteam3AsyncDepotFiles", HiddenStatic)!;
        foreach (var name in new[] { outside, "../keep-outside", "..\\keep-outside" })
        {
            var previous = new DepotManifest { Files = [Entry(name, [])] };
            var data = DepotData(root, [Entry("kept", [])], previous);
            await RejectAsync("unsafePath", () => (Task)method.Invoke(null, [new CancellationTokenSource(), Nested("GlobalDownloadCounter"), data, new HashSet<string> { "kept" }])!);
            Equal("untouched", File.ReadAllText(outside));
        }
    }
    private static Task LinksAndRoot()
    {
        var root = Folder("links"); var outside = Folder("link-outside");
        using var boundary = new SafeDirectory(root);
        Directory.CreateSymbolicLink(Path.Combine(root, "parent"), outside);
        File.CreateSymbolicLink(Path.Combine(root, "target"), Path.Combine(outside, "file"));
        Reject("unsafePath", () => boundary.Open(Path.Combine(root, "parent/new"), FileMode.Create));
        Reject("unsafePath", () => boundary.Open(Path.Combine(root, "target"), FileMode.Create));
        Reject("unsafePath", () => boundary.CreateDirectory(Path.Combine(root, "parent/created")));
        Reject("unsafePath", () => boundary.Delete(Path.Combine(root, "target")));
        using (var stream = boundary.Open(Path.Combine(root, "safe"), FileMode.Create)) stream.WriteByte(42);
        Reject("unsafePath", () => boundary.Move(Path.Combine(root, "safe"), Path.Combine(root, "target")));
        Directory.Move(root, root + "-original"); Directory.CreateDirectory(root);
        Reject("unsafePath", () => boundary.Open(Path.Combine(root, "replacement"), FileMode.Create));
        Equal(false, File.Exists(Path.Combine(root, "replacement")));
        Directory.Delete(root); Directory.CreateSymbolicLink(root, outside);
        Reject("unsafePath", () => boundary.CreateDirectory(Path.Combine(root, "replacement")));
        Equal(0, Directory.GetFileSystemEntries(outside).Length);
        return Task.CompletedTask;
    }
    [System.Runtime.InteropServices.DllImport("libc")] private static extern IntPtr realpath(string path, IntPtr buffer);
    [System.Runtime.InteropServices.DllImport("libc")] private static extern void free(IntPtr pointer);
    [System.Runtime.InteropServices.DllImport("libc")] private static extern int link(string from, string to);
    private static Task Hardlinks()
    {
        var root = Folder("hardlinks"); var outside = Path.Combine(fixture, "hardlink-original"); File.WriteAllText(outside, "untouched");
        Equal(0, link(outside, Path.Combine(root, "linked")));
        using var boundary = new SafeDirectory(root);
        Reject("unsafePath", () => boundary.Open(Path.Combine(root, "linked"), FileMode.Create));
        Equal("untouched", File.ReadAllText(outside));
        return Task.CompletedTask;
    }
    private static Task Integrity()
    {
        var root = Folder("integrity");
        using var boundary = new SafeDirectory(root); DownloadIO.Boundary = boundary;
        var file = Entry("project.json", [1, 2, 3]);
        Reject("integrityFailed", () => DownloadVerification.Verify(root, [file]));
        File.WriteAllBytes(Path.Combine(root, file.FileName), [1, 2]);
        Reject("integrityFailed", () => DownloadVerification.Verify(root, [file]));
        File.WriteAllBytes(Path.Combine(root, file.FileName), [1, 2, 4]);
        Reject("integrityFailed", () => DownloadVerification.Verify(root, [file]));
        File.WriteAllBytes(Path.Combine(root, file.FileName), [1, 2, 3]);
        DownloadVerification.Verify(root, [file]);
        Reject("integrityFailed", () => DownloadVerification.Verify(root, []));
        Reject("unsafePath", () => DownloadVerification.ValidateManifest([file, Entry("PROJECT.JSON", [1, 2, 3])]));
        Reject("unsafePath", () => DownloadVerification.ValidateManifest([Entry(".DepotDownloader/depot.config", [])]));
        var symlink = new DepotManifest.FileData("linked", [], (EDepotFileFlag)0, 0, [], "../outside", false, 0);
        Reject("unsafePath", () => DownloadVerification.ValidateManifest([symlink]));
        return Task.CompletedTask;
    }
    private static Task MissingManifest() => RejectAsync("missingManifest", () => ContentDownloader.DownloadPublishedDetailsAsync(431960, new PublishedFileDetails { result = 1, consumer_appid = 431960, publishedfileid = 1 }));
    private static Task Items()
    {
        Reject("unavailable", () => WorkshopItem.From(null));
        Reject("unavailable", () => WorkshopItem.From(new PublishedFileDetails { result = 9 }));
        Reject("accessDenied", () => WorkshopItem.From(new PublishedFileDetails { result = (uint)EResult.AccessDenied }));
        Reject("wrongApp", () => WorkshopItem.From(new PublishedFileDetails { result = 1, consumer_appid = 1 }));
        Reject("collection", () => WorkshopItem.From(new PublishedFileDetails { result = 1, consumer_appid = 431960, file_type = 2 }));
        var item = WorkshopItem.From(new PublishedFileDetails { result = 1, consumer_appid = 431960, publishedfileid = 123, title = "Fixture", file_description = "Description", preview_url = "file:///private/secret", file_size = 4 });
        Equal("123", item.id); Equal(null, item.previewURL); Equal((ulong?)4, item.size);
        return Task.CompletedTask;
    }
    private static Task Credentials()
    {
        var root = Folder("auth");
        AccountSettingsStore.LoadFromFile(root);
        AccountSettingsStore.Instance.LoginTokens["fixture-account"] = "fixture-refresh-token";
        AccountSettingsStore.Instance.GuardData["fixture-account"] = "fixture-guard-data";
        AccountSettingsStore.Save();
        Equal((UnixFileMode)448, File.GetUnixFileMode(root));
        Equal((UnixFileMode)384, File.GetUnixFileMode(Path.Combine(root, "credentials.json")));
        using var json = JsonDocument.Parse(File.ReadAllText(Path.Combine(root, "credentials.json")));
        Equal("guardData,refreshToken,username", string.Join(',', json.RootElement.EnumerateObject().Select(p => p.Name).Order()));
        Equal(false, File.Exists(Path.Combine(root, "credentials.json.tmp")));
        AccountSettingsStore.LoadFromFile(root);
        Equal("fixture-account", AccountSettingsStore.Instance.SavedUsername);
        Equal("fixture-refresh-token", AccountSettingsStore.Instance.LoginTokens["fixture-account"]);
        return Task.CompletedTask;
    }
    private static Task CredentialFailure()
    {
        var root = Folder("auth-failure");
        AccountSettingsStore.LoadFromFile(root);
        AccountSettingsStore.Instance.LoginTokens["fixture"] = "fixture";
        Directory.CreateDirectory(Path.Combine(root, "credentials.json.tmp"));
        Reject("credentialStorageFailed", AccountSettingsStore.Save);
        Directory.Delete(Path.Combine(root, "credentials.json.tmp"));
        var target = Path.Combine(fixture, "credential-target"); File.WriteAllText(target, "untouched");
        File.CreateSymbolicLink(Path.Combine(root, "credentials.json"), target);
        Reject("credentialStorageFailed", AccountSettingsStore.Save);
        Reject("credentialStorageFailed", () => AccountSettingsStore.LoadFromFile(root));
        Equal("untouched", File.ReadAllText(target));
        return Task.CompletedTask;
    }
    private static Task SearchPagination()
    {
        using var output = new StringWriter();
        typeof(HelperProgram).GetField("output", HiddenStatic)!.SetValue(null, output);
        var response = new CPublishedFile_QueryFiles_Response { total = 65 };
        response.publishedfiledetails.Add(new PublishedFileDetails { result = 1, consumer_appid = 431960, publishedfileid = 123, title = "Fixture" });
        response.publishedfiledetails.Add(new PublishedFileDetails { result = 1, consumer_appid = 1, publishedfileid = 456 });
        foreach (var page in new[] { 1, 2, 3 })
        {
            output.GetStringBuilder().Clear();
            HelperProgram.EmitSearchResults(Guid.NewGuid().ToString(), response, page);
            using var json = JsonDocument.Parse(output.ToString());
            var message = json.RootElement;
            Equal("items", message.GetProperty("type").GetString());
            Equal(1, message.GetProperty("items").GetArrayLength());
            Equal(page, message.GetProperty("page").GetInt32());
            Equal(true, message.TryGetProperty("pageSize", out var size));
            Equal(30, size.GetInt32());
            Equal(page < 3, page * size.GetInt32() < message.GetProperty("total").GetInt32());
        }
        return Task.CompletedTask;
    }
    private static async Task Authentication()
    {
        using var attempt = new AuthenticationAttempt();
        var starts = 0;
        await Task.WhenAll(Enumerable.Range(0, 16).Select(_ => Task.Run(() => { if (attempt.TryStart()) Interlocked.Increment(ref starts); })));
        Equal(1, starts);
        attempt.Cancel(); Equal(true, attempt.Token.IsCancellationRequested); Equal(false, attempt.TryStart());
        // Exercise the actual disconnect callback without connecting a Steam client.
        var session = (Steam3Session)System.Runtime.CompilerServices.RuntimeHelpers.GetUninitializedObject(typeof(Steam3Session));
        typeof(Steam3Session).GetField("authentication", BindingFlags.Instance | BindingFlags.NonPublic)!.SetValue(session, attempt);
        typeof(Steam3Session).GetField("abortedToken", BindingFlags.Instance | BindingFlags.NonPublic)!.SetValue(session, new CancellationTokenSource());
        typeof(Steam3Session).GetField("<IsLoggedOn>k__BackingField", BindingFlags.Instance | BindingFlags.NonPublic)!.SetValue(session, true);
        var events = new List<string>();
        BridgeContext.Emit = (type, _) => events.Add(type);
        var callback = typeof(Steam3Session).GetMethod("DisconnectedCallback", BindingFlags.Instance | BindingFlags.NonPublic)!;
        callback.Invoke(session, [null]);
        Equal(false, session.IsLoggedOn);
        Equal("disconnected", string.Join(',', events));
        callback.Invoke(session, [null]);
        Equal(1, events.Count);
    }
    private static async Task Guard()
    {
        var events = new List<string>();
        BridgeContext.Emit = (type, data) => events.Add(type + JsonSerializer.Serialize(data));
        var authenticator = new ConsoleAuthenticator();
        var pending = authenticator.GetEmailCodeAsync("private-email-fixture", true);
        Equal(true, BridgeContext.SupplyGuard("fixture-code"));
        Equal("fixture-code", await pending);
        Equal(false, events.Single().Contains("private-email-fixture"));
        Equal(false, events.Single().Contains("fixture-code"));
        var canceled = authenticator.GetDeviceCodeAsync(false);
        BridgeContext.CancelGuard();
        try { await canceled; throw new Exception("Guard request was not canceled"); } catch (TaskCanceledException) { }
        Equal(false, BridgeContext.SupplyGuard("late-code"));
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();
        var before = events.Count;
        try { await new ConsoleAuthenticator(cancellation.Token).GetDeviceCodeAsync(false); throw new Exception("Canceled session emitted a guard prompt"); }
        catch (OperationCanceledException) { }
        Equal(before, events.Count);
    }
}
