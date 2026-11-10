// This file is subject to the terms and conditions defined in ../LICENSE.
// Modified for Workshop Wallpaper Bridge: codes only arrive over the JSON pipe.
using SteamKit2.Authentication;
using WorkshopBridge;

namespace DepotDownloader;

internal sealed class ConsoleAuthenticator(CancellationToken cancellation = default) : IAuthenticator
{
    private Task<string> Request(string prompt)
    {
        cancellation.ThrowIfCancellationRequested();
        return BridgeContext.RequestGuard(prompt).WaitAsync(cancellation);
    }
    public Task<string> GetDeviceCodeAsync(bool previousCodeWasIncorrect) => Request("twoFactor");
    public Task<string> GetEmailCodeAsync(string email, bool previousCodeWasIncorrect) => Request("emailCode");
    public Task<bool> AcceptDeviceConfirmationAsync()
    {
        cancellation.ThrowIfCancellationRequested();
        BridgeContext.Emit("authPrompt", new { prompt = "mobileApproval", message = "Approve sign-in in the Steam mobile app." });
        return Task.FromResult(true);
    }
}
