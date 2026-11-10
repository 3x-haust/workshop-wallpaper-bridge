using System.Security.Cryptography;
using SteamKit2;

namespace WorkshopBridge;

internal static class DownloadVerification
{
    public static void ValidateName(string name)
    {
        SafeDirectory.ValidateRelative(name);
        if (name.Split('/')[0].Equals(".DepotDownloader", StringComparison.OrdinalIgnoreCase)) throw new HelperFailure("unsafePath");
    }

    public static void ValidateManifest(IEnumerable<DepotManifest.FileData> files)
    {
        var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var file in files)
        {
            ValidateName(file.FileName);
            if (!string.IsNullOrEmpty(file.LinkTarget) || !names.Add(file.FileName.Normalize())) throw new HelperFailure("unsafePath");
        }
    }

    public static void Verify(string root, IEnumerable<DepotManifest.FileData> files)
    {
        var count = 0;
        foreach (var file in files)
        {
            ValidateName(file.FileName);
            if (file.Flags.HasFlag(EDepotFileFlag.Directory)) continue;
            count++;
            var path = DownloadIO.Combine(root, file.FileName);
            try
            {
                using var stream = DownloadIO.Boundary.Open(path, FileMode.Open, FileAccess.Read);
                if ((ulong)stream.Length != file.TotalSize || file.FileHash is not { Length: 20 } || !SHA1.HashData(stream).SequenceEqual(file.FileHash))
                    throw new HelperFailure("integrityFailed");
            }
            catch (HelperFailure failure) when (failure.Code == "unsafePath" && !File.Exists(path)) { throw new HelperFailure("integrityFailed"); }
            catch (IOException) { throw new HelperFailure("integrityFailed"); }
        }
        if (count == 0) throw new HelperFailure("integrityFailed");
        DownloadIO.Boundary.CheckRoot();
    }
}
