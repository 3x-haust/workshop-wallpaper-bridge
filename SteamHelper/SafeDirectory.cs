using Microsoft.Win32.SafeHandles;
using System.Runtime.InteropServices;

namespace WorkshopBridge;

// macOS-only descriptor-relative I/O: no write follows an untrusted symlink.
internal sealed class SafeDirectory : IDisposable
{
    private const int DirectoryFlag = 0x100000, NoFollow = 0x100, CloseOnExec = 0x1000000;
    private const int CreateFlag = 0x200, ExclusiveFlag = 0x800;
    private readonly SafeFileHandle rootHandle;
    private readonly (int Device, long Inode) identity;
    public string Root { get; }

    public SafeDirectory(string directory, bool create = false)
    {
        if (!OperatingSystem.IsMacOS()) throw new PlatformNotSupportedException();
        if (!Path.IsPathFullyQualified(directory)) throw new HelperFailure("unsafePath");
        Root = Path.TrimEndingDirectorySeparator(Path.GetFullPath(directory));
        if (Root == "/") throw new HelperFailure("unsafePath");
        rootHandle = OpenDirectory(Root, create);
        identity = Identity(rootHandle);
    }

    public static void ValidateRelative(string relative)
    {
        if (string.IsNullOrWhiteSpace(relative) || Path.IsPathRooted(relative) || relative.Contains('\\') || relative.Contains(':') || relative.Contains('\0'))
            throw new HelperFailure("unsafePath");
        if (relative.Split('/').Any(segment => segment is "" or "." or "..")) throw new HelperFailure("unsafePath");
    }

    public string Combine(string directory, string relative)
    {
        ValidateRelative(relative);
        var result = Path.Combine(directory, relative);
        Check(result);
        return result;
    }

    public void MakePrivate()
    {
        CheckRoot();
        if (fchmod(Fd(rootHandle), 0x1c0) != 0) Fail();
    }

    public void CheckRoot()
    {
        using var current = OpenDirectory(Root);
        if (Identity(current) != identity) throw new HelperFailure("unsafePath");
    }

    private string[] Segments(string path)
    {
        CheckRoot();
        var full = Path.GetFullPath(path);
        if (full == Root) return [];
        if (!full.StartsWith(Root + "/", StringComparison.Ordinal)) throw new HelperFailure("unsafePath");
        var relative = full[(Root.Length + 1)..];
        ValidateRelative(relative);
        return relative.Split('/');
    }

    // Used for metadata reads as well; missing descendants are allowed, links are not.
    public string Check(string path)
    {
        var segments = Segments(path);
        var current = Root;
        foreach (var segment in segments)
        {
            current = Path.Combine(current, segment);
            try
            {
                if ((File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0) throw new HelperFailure("unsafePath");
            }
            catch (FileNotFoundException) { }
            catch (DirectoryNotFoundException) { }
        }
        return path;
    }

    private SafeFileHandle Parent(string path, out string name)
    {
        var segments = Segments(path);
        if (segments.Length == 0) throw new HelperFailure("unsafePath");
        name = segments[^1];
        var parent = Handle(dup(Fd(rootHandle)));
        try
        {
            foreach (var segment in segments[..^1])
            {
                var next = Handle(openat(Fd(parent), segment, DirectoryFlag | NoFollow | CloseOnExec, 0));
                parent.Dispose();
                parent = next;
            }
            return parent;
        }
        catch { parent.Dispose(); throw; }
    }

    public void CreateDirectory(string path)
    {
        var segments = Segments(path);
        using var start = Handle(dup(Fd(rootHandle)));
        var parent = start;
        try
        {
            foreach (var segment in segments)
            {
                if (mkdirat(Fd(parent), segment, 0x1c0) != 0 && Marshal.GetLastPInvokeError() != 17) Fail(); // 0700 / EEXIST
                var next = Handle(openat(Fd(parent), segment, DirectoryFlag | NoFollow | CloseOnExec, 0));
                if (parent != start) parent.Dispose();
                parent = next;
            }
        }
        finally { if (parent != start) parent.Dispose(); }
    }

    public FileStream Open(string path, FileMode mode, FileAccess access = FileAccess.ReadWrite)
    {
        using var parent = Parent(path, out var name);
        var flags = NoFollow | CloseOnExec | (access == FileAccess.Read ? 0 : access == FileAccess.Write ? 1 : 2);
        if (mode is FileMode.Create or FileMode.CreateNew or FileMode.OpenOrCreate) flags |= CreateFlag;
        if (mode == FileMode.CreateNew) flags |= ExclusiveFlag;
        var handle = Handle(openat(Fd(parent), name, flags, 0x180)); // 0600 at creation, before content is written
        try
        {
            var stat = Stat(handle);
            var type = BitConverter.ToUInt16(stat, 4) & 0xf000;
            if (type != 0x8000 || BitConverter.ToUInt16(stat, 6) != 1) throw new HelperFailure("unsafePath");
            var stream = new FileStream(handle, access);
            if (mode is FileMode.Create or FileMode.Truncate) stream.SetLength(0);
            return stream;
        }
        catch { handle.Dispose(); throw; }
    }

    public void Delete(string path)
    {
        Check(path);
        using var parent = Parent(path, out var name);
        if (unlinkat(Fd(parent), name, 0) != 0) Fail();
    }

    public void Move(string source, string destination)
    {
        Check(source); Check(destination);
        using var from = Parent(source, out var fromName);
        using var to = Parent(destination, out var toName);
        if (renameat(Fd(from), fromName, Fd(to), toName) != 0) Fail();
    }

    public void SetExecutable(string path, bool executable)
    {
        using var stream = Open(path, FileMode.Open);
        if (fchmod(Fd(stream.SafeFileHandle), executable ? 0x1c0 : 0x180) != 0) Fail();
    }

    private static SafeFileHandle OpenDirectory(string path, bool create = false)
    {
        var parent = Handle(open("/", DirectoryFlag | NoFollow | CloseOnExec, 0));
        try
        {
            foreach (var segment in path.Split('/', StringSplitOptions.RemoveEmptyEntries))
            {
                var fd = openat(Fd(parent), segment, DirectoryFlag | NoFollow | CloseOnExec, 0);
                if (fd < 0 && create && Marshal.GetLastPInvokeError() == 2) // ENOENT
                {
                    if (mkdirat(Fd(parent), segment, 0x1c0) != 0 && Marshal.GetLastPInvokeError() != 17) Fail(); // 0700 / EEXIST
                    fd = openat(Fd(parent), segment, DirectoryFlag | NoFollow | CloseOnExec, 0);
                }
                var next = Handle(fd);
                parent.Dispose();
                parent = next;
            }
            return parent;
        }
        catch { parent.Dispose(); throw; }
    }
    private static int Fd(SafeFileHandle handle) => handle.DangerousGetHandle().ToInt32();
    private static SafeFileHandle Handle(int fd) => fd < 0 ? throw new HelperFailure("unsafePath") : new SafeFileHandle((IntPtr)fd, true);
    private static byte[] Stat(SafeFileHandle handle)
    {
        var buffer = new byte[144]; // Darwin arm64 struct stat64; device/mode/nlink/inode offsets 0/4/6/8.
        if (fstat(Fd(handle), buffer) != 0) Fail();
        return buffer;
    }
    private static (int, long) Identity(SafeFileHandle handle)
    {
        var stat = Stat(handle);
        return (BitConverter.ToInt32(stat, 0), BitConverter.ToInt64(stat, 8));
    }
    private static void Fail() => throw new HelperFailure("unsafePath");
    public void Dispose() => rootHandle.Dispose();

    [DllImport("wwb_posix", EntryPoint = "wwb_open", SetLastError = true)] private static extern int open(string path, int flags, int mode);
    [DllImport("wwb_posix", EntryPoint = "wwb_openat", SetLastError = true)] private static extern int openat(int fd, string path, int flags, int mode);
    [DllImport("libc", SetLastError = true)] private static extern int mkdirat(int fd, string path, int mode);
    [DllImport("libc", SetLastError = true)] private static extern int unlinkat(int fd, string path, int flags);
    [DllImport("libc", SetLastError = true)] private static extern int renameat(int from, string source, int to, string destination);
    [DllImport("libc", SetLastError = true)] private static extern int dup(int fd);
    [DllImport("libc", SetLastError = true)] private static extern int fstat(int fd, [Out] byte[] stat);
    [DllImport("libc", SetLastError = true)] private static extern int fchmod(int fd, int mode);
}

internal static class DownloadIO
{
    public static SafeDirectory Boundary { get; set; }
    public static string Combine(string directory, string relative) => Boundary.Combine(directory, relative);
    public static string Check(string path) => Boundary.Check(path);
    public static void CreateDirectory(string path) => Boundary.CreateDirectory(path);
    public static FileStream Open(string path, FileMode mode) => Boundary.Open(path, mode);
    public static FileStream OpenWrite(string path) => Boundary.Open(path, FileMode.Create, FileAccess.Write);
    public static FileStream Create(string path) => Boundary.Open(path, FileMode.Create);
    public static bool Exists(string path) => File.Exists(Check(path));
    public static void Delete(string path) => Boundary.Delete(path);
    public static void Move(string from, string to) => Boundary.Move(from, to);
    public static byte[] ReadAllBytes(string path) { using var f = Boundary.Open(path, FileMode.Open, FileAccess.Read); using var b = new MemoryStream(); f.CopyTo(b); return b.ToArray(); }
    public static void WriteAllBytes(string path, byte[] bytes) { using var f = OpenWrite(path); f.Write(bytes); }
}
