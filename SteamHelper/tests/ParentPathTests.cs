using DepotDownloader;
using WorkshopBridge;

internal static class ParentPathTests
{
    public static Task Run(string fixture)
    {
        var failures = new List<Exception>();
        var index = 0;
        foreach (var (name, test) in new (string, Action<string>)[]
        {
            ("download roots reject ancestor symlinks", DownloadAncestor),
            ("credentials reject ancestor symlinks before creating directories", MissingCredentials),
            ("credentials reject ancestor symlinks before changing permissions", ExistingCredentials),
            ("replaced ancestors reject writes even when root identity matches", ReplacedAncestor),
            ("credentials create private nested directories without changing parents", PrivateCreation)
        })
        {
            var root = Path.Combine(fixture, "parent-path-" + index++);
            Directory.CreateDirectory(root);
            try { test(root); }
            catch (Exception error) { failures.Add(new Exception(name + ": " + error.Message, error)); }
        }
        if (failures.Count != 0) throw new AggregateException(failures);
        return Task.CompletedTask;
    }

    private static void DownloadAncestor(string fixture)
    {
        var outside = Path.Combine(fixture, "outside");
        var root = Path.Combine(outside, "nested", "download");
        Directory.CreateDirectory(root);
        File.WriteAllText(Path.Combine(root, "keep"), "unchanged");
        File.SetUnixFileMode(root, (UnixFileMode)493);
        var link = Path.Combine(fixture, "linked-parent");
        Directory.CreateSymbolicLink(link, outside);
        RejectWithoutChanges("unsafePath", outside, () =>
        {
            using var boundary = new SafeDirectory(Path.Combine(link, "nested", "download"));
            boundary.MakePrivate();
            using var stream = boundary.Open(Path.Combine(boundary.Root, "new"), FileMode.Create);
            stream.WriteByte(42);
        });
    }

    private static void MissingCredentials(string fixture)
    {
        var outside = Path.Combine(fixture, "outside");
        Directory.CreateDirectory(outside);
        File.WriteAllText(Path.Combine(outside, "keep"), "unchanged");
        var link = Path.Combine(fixture, "linked-parent");
        Directory.CreateSymbolicLink(link, outside);
        RejectWithoutChanges("credentialStorageFailed", outside,
            () => AccountSettingsStore.LoadFromFile(Path.Combine(link, "missing", "Steam")));
        var dangling = Path.Combine(fixture, "dangling");
        Directory.CreateSymbolicLink(dangling, Path.Combine(outside, "absent"));
        RejectWithoutChanges("credentialStorageFailed", outside,
            () => AccountSettingsStore.LoadFromFile(Path.Combine(dangling, "Steam")));
    }

    private static void ExistingCredentials(string fixture)
    {
        var outside = Path.Combine(fixture, "outside");
        var root = Path.Combine(outside, "Steam");
        Directory.CreateDirectory(root);
        var credentials = Path.Combine(root, "credentials.json");
        File.WriteAllText(credentials, "{\"username\":\"fixture\",\"refreshToken\":\"fixture-token\",\"guardData\":null}");
        File.SetUnixFileMode(root, (UnixFileMode)493);
        File.SetUnixFileMode(credentials, (UnixFileMode)420);
        var link = Path.Combine(fixture, "linked-parent");
        Directory.CreateSymbolicLink(link, outside);
        RejectWithoutChanges("credentialStorageFailed", outside,
            () => AccountSettingsStore.LoadFromFile(Path.Combine(link, "Steam")));
        var directLink = Path.Combine(fixture, "linked-root");
        Directory.CreateSymbolicLink(directLink, root);
        RejectWithoutChanges("credentialStorageFailed", outside,
            () => AccountSettingsStore.LoadFromFile(directLink));
    }

    private static void ReplacedAncestor(string fixture)
    {
        var ancestor = Path.Combine(fixture, "parent");
        var root = Path.Combine(ancestor, "root");
        Directory.CreateDirectory(root);
        File.SetUnixFileMode(root, (UnixFileMode)493);
        File.WriteAllText(Path.Combine(root, "keep"), "unchanged");
        using var boundary = new SafeDirectory(root);
        var moved = ancestor + "-original";
        Directory.Move(ancestor, moved);
        Directory.CreateSymbolicLink(ancestor, moved);
        RejectWithoutChanges("unsafePath", moved, boundary.MakePrivate);
        RejectWithoutChanges("unsafePath", moved, () => boundary.CreateDirectory(Path.Combine(root, "new-directory")));
        RejectWithoutChanges("unsafePath", moved, () =>
        {
            using var stream = boundary.Open(Path.Combine(root, "keep"), FileMode.Create);
            stream.WriteByte(42);
        });
    }

    private static void PrivateCreation(string fixture)
    {
        File.SetUnixFileMode(fixture, (UnixFileMode)493);
        var root = Path.Combine(fixture, "new-parent", "Steam");
        AccountSettingsStore.LoadFromFile(root);
        Equal((UnixFileMode)493, File.GetUnixFileMode(fixture));
        Equal((UnixFileMode)448, File.GetUnixFileMode(Path.GetDirectoryName(root)!));
        Equal((UnixFileMode)448, File.GetUnixFileMode(root));
        AccountSettingsStore.Instance.LoginTokens["fixture"] = "fixture-token";
        AccountSettingsStore.Save();
        Equal((UnixFileMode)384, File.GetUnixFileMode(Path.Combine(root, "credentials.json")));
        AccountSettingsStore.LoadFromFile(root);
        Equal("fixture-token", AccountSettingsStore.Instance.LoginTokens["fixture"]);
    }

    private static void RejectWithoutChanges(string code, string outside, Action action)
    {
        var before = Snapshot(outside);
        string actual = null;
        try { action(); }
        catch (HelperFailure error) { actual = error.Code; }
        Equal(before, Snapshot(outside));
        Equal(code, actual);
    }

    private static string Snapshot(string root) => string.Join('\n',
        new[] { root }.Concat(Directory.EnumerateFileSystemEntries(root, "*", SearchOption.AllDirectories)).Order()
            .Select(path => Path.GetRelativePath(root, path) + ":" + File.GetUnixFileMode(path) + ":" +
                (Directory.Exists(path) ? "directory" : Convert.ToBase64String(File.ReadAllBytes(path)))));

    private static void Equal<T>(T expected, T actual)
    {
        if (!EqualityComparer<T>.Default.Equals(expected, actual))
            throw new Exception($"Expected {expected}; got {actual}");
    }
}
