namespace WorkshopBridge;

internal static class BridgeContext
{
    public static Action<string, object> Emit = (_, _) => { };
    public static Exception AuthenticationError;
    private static TaskCompletionSource<string> guard;
    private static readonly object sync = new();

    public static Task<string> RequestGuard(string prompt)
    {
        lock (sync)
        {
            guard?.TrySetCanceled();
            guard = new(TaskCreationOptions.RunContinuationsAsynchronously);
            Emit("authPrompt", new { prompt, message = "Enter the Steam Guard code to continue." });
            return guard.Task;
        }
    }
    public static bool SupplyGuard(string code)
    {
        lock (sync)
        {
            if (guard == null || string.IsNullOrWhiteSpace(code)) return false;
            var accepted = guard.TrySetResult(code);
            guard = null;
            return accepted;
        }
    }
    public static void CancelGuard()
    {
        lock (sync) { guard?.TrySetCanceled(); guard = null; }
    }
}

// A connection callback may arrive again while Steam's QR approval is pending.
// One session owns exactly one authentication task; a disconnect cancels it.
internal sealed class AuthenticationAttempt : IDisposable
{
    private int started;
    private readonly CancellationTokenSource cancellation = new();
    public CancellationToken Token => cancellation.Token;
    public bool TryStart() => !Token.IsCancellationRequested && Interlocked.CompareExchange(ref started, 1, 0) == 0;
    public void Cancel() => cancellation.Cancel();
    public void Dispose() { cancellation.Cancel(); cancellation.Dispose(); }
}
