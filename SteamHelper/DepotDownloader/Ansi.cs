// This file is subject to the terms and conditions defined in ../LICENSE.
// Modified for Workshop Wallpaper Bridge: structured progress, no terminal escapes.
using WorkshopBridge;
namespace DepotDownloader;
internal static class Ansi
{
    public enum ProgressState { Hidden, Default, Error, Indeterminate, Warning }
    public static void Progress(ulong downloaded, ulong total) => BridgeContext.Emit("progress", new { completed = downloaded, total });
    public static void Progress(ProgressState state, byte progress = 0) { }
}
