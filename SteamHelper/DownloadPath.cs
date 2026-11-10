namespace WorkshopBridge;

internal static class DownloadPath
{
    public static string Combine(params string[] parts)
    {
        if (parts.Length == 0) throw new HelperFailure("unsafePath");
        if (!Path.IsPathRooted(parts[0])) SafeDirectory.ValidateRelative(parts[0]);
        foreach (var part in parts.Skip(1)) SafeDirectory.ValidateRelative(part);
        var result = Path.Combine(parts);
        if (Path.IsPathRooted(result)) DownloadIO.Check(result);
        return result;
    }
    public static string GetDirectoryName(string path) => Path.GetDirectoryName(DownloadIO.Check(path));
}
