// This file is subject to the terms and conditions defined in ../LICENSE.
// Modified for Workshop Wallpaper Bridge: all permission changes are descriptor-relative.
using WorkshopBridge;
namespace DepotDownloader;
internal static class PlatformUtilities
{
    public static void SetExecutable(string path, bool value) => DownloadIO.Boundary.SetExecutable(path, value);
}
