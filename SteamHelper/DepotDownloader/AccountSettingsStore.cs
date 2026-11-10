// This file is subject to the terms and conditions defined in ../LICENSE.
// Modified for Workshop Wallpaper Bridge: explicit private JSON credential storage.
using System.Collections.Concurrent;
using System.Text.Json;
using WorkshopBridge;

namespace DepotDownloader;

internal sealed class AccountSettingsStore
{
    public ConcurrentDictionary<string, int> ContentServerPenalty { get; } = new();
    public Dictionary<string, string> LoginTokens { get; } = new(StringComparer.OrdinalIgnoreCase);
    public Dictionary<string, string> GuardData { get; } = new(StringComparer.OrdinalIgnoreCase);
    public static AccountSettingsStore Instance;
    private SafeDirectory directory;
    public string SavedUsername => LoginTokens.Keys.SingleOrDefault();
    private sealed record Credentials(string username, string refreshToken, string guardData);

    public static void LoadFromFile(string dataDirectory)
    {
        try
        {
            if (!Path.IsPathFullyQualified(dataDirectory)) throw new IOException();
            var store = new AccountSettingsStore { directory = new SafeDirectory(dataDirectory, create: true) };
            store.directory.MakePrivate();
            var path = store.directory.Check(Path.Combine(store.directory.Root, "credentials.json"));
            if (File.Exists(path))
            {
                using var stream = store.directory.Open(path, FileMode.Open, FileAccess.Read);
                File.SetUnixFileMode(stream.SafeFileHandle, UnixFileMode.UserRead | UnixFileMode.UserWrite);
                if (stream.Length > 65536) throw new IOException();
                var saved = JsonSerializer.Deserialize<Credentials>(stream);
                if (saved is null || string.IsNullOrWhiteSpace(saved.username) || string.IsNullOrWhiteSpace(saved.refreshToken)) throw new IOException();
                store.LoginTokens[saved.username] = saved.refreshToken;
                if (saved.guardData != null) store.GuardData[saved.username] = saved.guardData;
            }
            Instance?.directory.Dispose();
            Instance = store;
        }
        catch { throw new HelperFailure("credentialStorageFailed"); }
    }

    public static void Save()
    {
        try
        {
            var store = Instance;
            var path = Path.Combine(store.directory.Root, "credentials.json");
            store.directory.Check(path);
            if (store.LoginTokens.Count == 0)
            {
                if (File.Exists(path)) store.directory.Delete(path);
                return;
            }
            var account = store.LoginTokens.Single();
            store.GuardData.TryGetValue(account.Key, out var guard);
            var temporary = Path.Combine(store.directory.Root, "credentials.json.tmp");
            if (File.Exists(store.directory.Check(temporary))) store.directory.Delete(temporary);
            using (var stream = store.directory.Open(temporary, FileMode.CreateNew, FileAccess.Write))
            {
                JsonSerializer.Serialize(stream, new Credentials(account.Key, account.Value, guard));
                stream.Flush(flushToDisk: true);
            }
            store.directory.Move(temporary, path);
        }
        catch { throw new HelperFailure("credentialStorageFailed"); }
    }
}
