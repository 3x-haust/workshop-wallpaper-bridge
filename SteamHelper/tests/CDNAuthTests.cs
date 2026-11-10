using System.Reflection;
using System.Runtime.CompilerServices;
using DepotDownloader;
using SteamKit2;
using SteamKit2.CDN;
using WorkshopBridge;

internal static class CDNAuthTests
{
    private static readonly Server Server = CreateServer();

    private static Server CreateServer()
    {
        var server = new Server();
        typeof(Server).GetProperty("Host")!.SetValue(server, "cdn.invalid");
        return server;
    }
    private static readonly TimeSpan Deadline = TimeSpan.FromSeconds(2);

    public static async Task Run(TextWriter report)
    {
        var failures = new List<Exception>();
        foreach (var (name, test) in new (string, Func<Task>)[]
        {
            ("successful response completes cached and duplicate waiters with the same token", () => Response(EResult.OK, null)),
            ("AccessDenied faults cached and duplicate waiters with accessDenied", () => Response(EResult.AccessDenied, "accessDenied")),
            ("other negative responses fault every waiter with unavailable", () => Response(EResult.Fail, "unavailable")),
            ("asynchronous request exceptions fault every waiter with unavailable", () => ExceptionResponse(false)),
            ("synchronous request exceptions fault the cached waiter with unavailable", SynchronousException),
            ("request cancellation faults every waiter with disconnected", () => ExceptionResponse(true)),
            ("session cancellation releases every waiter while the network request remains pending", SessionCancellation),
            ("an already aborted session rejects the request without calling Steam", AlreadyAborted)
        })
        {
            try { await test(); report.WriteLine("PASS " + name); }
            catch (Exception error) { failures.Add(new Exception(name + ": " + error.Message, error)); }
        }
        if (failures.Count != 0) throw new AggregateException(failures);
        report.WriteLine("PASS 8 CDN authentication tests");
    }

    private static SteamContent.CDNAuthToken Token(EResult result)
    {
        var token = (SteamContent.CDNAuthToken)RuntimeHelpers.GetUninitializedObject(typeof(SteamContent.CDNAuthToken));
        typeof(SteamContent.CDNAuthToken).GetProperty("Result")!.SetValue(token, result);
        typeof(SteamContent.CDNAuthToken).GetProperty("Token")!.SetValue(token, "fixture-token");
        return token;
    }

    private static async Task Response(EResult result, string code)
    {
        var response = Token(result);
        await PendingRequest(source => source.SetResult(response), code, response);
    }

    private static Task ExceptionResponse(bool cancelled) => PendingRequest(source =>
    {
        if (cancelled) source.SetCanceled();
        else source.SetException(new IOException("private upstream diagnostic"));
    }, cancelled ? "disconnected" : "unavailable");

    private static async Task PendingRequest(Action<TaskCompletionSource<SteamContent.CDNAuthToken>> finish,
        string code, SteamContent.CDNAuthToken response = null)
    {
        var source = new TaskCompletionSource<SteamContent.CDNAuthToken>(TaskCreationOptions.RunContinuationsAsynchronously);
        var calls = 0;
        var session = new Steam3Session((app, depot, host) =>
        {
            Equal(431960u, app); Equal(42u, depot); Equal(Server.Host, host);
            calls++;
            return source.Task;
        });
        var first = session.RequestCDNAuthToken(431960, 42, Server);
        var cached = session.CDNAuthTokens[(42, Server.Host)].Task;
        var duplicate = session.RequestCDNAuthToken(431960, 42, Server);
        Equal(1, calls);
        Equal(false, first.IsCompleted);
        Equal(false, cached.IsCompleted);
        var duplicateWasPending = !duplicate.IsCompleted;

        finish(source);

        // Check the downloader's cached task first: a request may return while this is stranded.
        await Outcome(cached, code);
        await Outcome(first, code);
        await Outcome(duplicate, code);
        Equal(true, duplicateWasPending);
        if (code == null) Equal(response, await cached);
        var subsequent = session.RequestCDNAuthToken(431960, 42, Server);
        await Outcome(subsequent, code);
        Equal(1, calls);
        Equal(cached, session.CDNAuthTokens[(42, Server.Host)].Task);
    }

    private static async Task SynchronousException()
    {
        var session = new Steam3Session((_, _, _) => throw new IOException("private upstream diagnostic"));
        var request = session.RequestCDNAuthToken(431960, 42, Server);
        await Outcome(session.CDNAuthTokens[(42, Server.Host)].Task, "unavailable");
        await Outcome(request, "unavailable");
    }

    private static CancellationTokenSource AbortToken(Steam3Session session) =>
        (CancellationTokenSource)typeof(Steam3Session).GetField("abortedToken", BindingFlags.NonPublic | BindingFlags.Instance)!.GetValue(session)!;

    private static async Task SessionCancellation()
    {
        var source = new TaskCompletionSource<SteamContent.CDNAuthToken>(TaskCreationOptions.RunContinuationsAsynchronously);
        var session = new Steam3Session((_, _, _) => source.Task);
        var request = session.RequestCDNAuthToken(431960, 42, Server);
        var duplicate = session.RequestCDNAuthToken(431960, 42, Server);
        AbortToken(session).Cancel();
        await Outcome(session.CDNAuthTokens[(42, Server.Host)].Task, "disconnected");
        await Outcome(request, "disconnected");
        await Outcome(duplicate, "disconnected");
        Equal(false, source.Task.IsCompleted);
    }

    private static async Task AlreadyAborted()
    {
        var calls = 0;
        var session = new Steam3Session((_, _, _) => { calls++; return Task.FromResult(Token(EResult.OK)); });
        typeof(Steam3Session).GetField("bAborted", BindingFlags.NonPublic | BindingFlags.Instance)!.SetValue(session, true);
        AbortToken(session).Cancel();
        await Outcome(session.RequestCDNAuthToken(431960, 42, Server), "disconnected");
        Equal(0, calls);
    }

    private static async Task Outcome(Task task, string code)
    {
        try { await task.WaitAsync(Deadline); }
        catch (TimeoutException) { throw new Exception("CDN auth waiter remained pending after its request ended"); }
        catch (HelperFailure error)
        {
            if (code == null) throw;
            Equal(code, error.Code); Equal(code, error.Message); return;
        }
        if (code != null) throw new Exception("Expected typed failure: " + code);
    }

    private static void Equal<T>(T expected, T actual)
    {
        if (!EqualityComparer<T>.Default.Equals(expected, actual))
            throw new Exception($"Expected {expected}; got {actual}");
    }
}
