namespace WorkshopBridge;

internal sealed class HelperFailure(string code) : Exception(code)
{
    public string Code { get; } = code;
    public static string MessageFor(string code) => code switch
    {
        "authenticationRequired" => "Sign in to Steam to continue.",
        "authenticationFailed" => "Steam sign-in failed. Please sign in again.",
        "credentialsUnavailable" => "Saved Steam sign-in is unavailable. Please sign in again.",
        "credentialStorageFailed" => "Steam sign-in could not be saved securely.",
        "disconnected" => "The Steam connection ended. Please sign in again.",
        "accessDenied" => "Steam did not grant access to this item.",
        "wrongApp" => "This item does not belong to Wallpaper Engine.",
        "collection" => "Collections cannot be downloaded as wallpapers.",
        "unavailable" => "This Workshop item is unavailable.",
        "missingManifest" => "Steam did not provide downloadable content for this item.",
        "integrityFailed" => "Downloaded content did not pass verification.",
        "unsafePath" => "The download contains an unsafe file path.",
        "invalidRequest" => "The helper request is invalid.",
        "busy" => "Another Steam request is still in progress.",
        _ => "The Steam request could not be completed."
    };
}
