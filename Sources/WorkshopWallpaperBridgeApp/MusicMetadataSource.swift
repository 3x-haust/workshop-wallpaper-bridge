import AppKit
import CryptoKit

struct WallpaperMediaSnapshot: Sendable {
    var enabled = false
    var state = 0
    var title = ""
    var artist = ""
    var albumTitle = ""
    var albumArtist = ""
    var position: Double = 0
    var duration: Double = 0
    var receivedAt = Date()
    var artwork: Data?
    var artworkRevision = ""

    func frame(at date: Date = Date()) -> [String: Any] {
        let elapsed = state == 1 ? max(0, min(3, date.timeIntervalSince(receivedAt))) : 0
        return ["enabled": enabled, "state": state, "title": title, "artist": artist,
                "albumTitle": albumTitle, "albumArtist": albumArtist,
                "position": min(duration.rounded(.down), max(0, position + elapsed)), "duration": duration.rounded(.down),
                "hasThumbnail": artwork != nil, "artworkRevision": artworkRevision]
    }
}

/// Reads the players' documented scripting interfaces. Never starts a player,
/// changes playback, or injects code into an entitled system process.
@MainActor
final class MusicMetadataSource: ObservableObject {
    static let shared = MusicMetadataSource()
    @Published private(set) var status = ""
    private(set) var snapshot = WallpaperMediaSnapshot()
    private var enabled = false
    private var consumers = Set<UUID>()
    private var timer: Timer?
    private var generation = 0
    private var inFlight = false
    private var preferredPlayer: String?
    private var artworkKey = ""
    private var cachedArtwork: Data?

    func acquire() -> UUID {
        let id = UUID(), wasEmpty = consumers.isEmpty
        consumers.insert(id); if wasEmpty { reconcile() }; return id
    }
    func release(_ id: UUID) { consumers.remove(id); if consumers.isEmpty { reconcile() } }
    func setEnabled(_ value: Bool) { guard enabled != value else { return }; enabled = value; reconcile() }
    private func reconcile() {
        generation += 1
        timer?.invalidate(); timer = nil
        guard enabled, !consumers.isEmpty else {
            snapshot = WallpaperMediaSnapshot(); status = ""; cachedArtwork = nil; artworkKey = ""; return
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        poll()
    }
    private func poll() {
        guard enabled, !consumers.isEmpty, !inFlight else { return }
        let players = ["com.apple.Music", "com.spotify.client"].filter {
            !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty
        }.sorted { $0 == preferredPlayer && $1 != preferredPlayer }
        guard !players.isEmpty else {
            snapshot = WallpaperMediaSnapshot(enabled: true); status = ""; cachedArtwork = nil; artworkKey = ""; return
        }
        inFlight = true
        let token = generation
        Task { [weak self] in
            let results = await Task.detached(priority: .utility) { players.map { ($0, Self.read(player: $0)) } }.value
            guard let self else { return }
            defer { self.inFlight = false }
            guard self.generation == token, self.enabled, !self.consumers.isEmpty else { return }
            let selected = results.first { $0.1.snapshot?.state == 1 } ?? results.first { $0.1.snapshot != nil }
            guard let selected, var next = selected.1.snapshot else {
                self.snapshot = WallpaperMediaSnapshot(enabled: true)
                self.status = results.compactMap { $0.1.error }.first ?? ""
                return
            }
            self.preferredPlayer = selected.0
            let key = selected.0 + "|" + next.title + "|" + next.artist + "|" + next.albumTitle
            if key != self.artworkKey {
                self.artworkKey = key; self.cachedArtwork = nil
                if let url = selected.1.artworkURL {
                    self.cachedArtwork = await Self.loadArtwork(url)
                    guard self.generation == token, self.enabled else { return }
                }
            }
            if next.artwork == nil { next.artwork = self.cachedArtwork }
            if let data = next.artwork { next.artworkRevision = SHA256.hash(data: data).description }
            self.snapshot = next; self.status = ""
        }
    }

    struct ReadResult: Sendable {
        var snapshot: WallpaperMediaSnapshot?
        var artworkURL: URL?
        var error: String?
    }

    nonisolated static func read(player: String) -> ReadResult {
        guard ["com.apple.Music", "com.spotify.client"].contains(player) else { return ReadResult() }
        let spotify = player == "com.spotify.client"
        let artwork = spotify ? "set cover to artwork url of t" : "try\nset cover to raw data of artwork 1 of t\nend try"
        let script = """
        with timeout of 2 seconds
            tell application id "\(player)"
                if not running then return {}
                set playback to player state as string
                if playback is "stopped" then return {"stopped"}
                set t to current track
                set cover to ""
                \(artwork)
                return {playback, name of t, artist of t, album of t, player position, duration of t, cover}
            end tell
        end timeout
        """
        var error: NSDictionary?
        guard let descriptor = NSAppleScript(source: script)?.executeAndReturnError(&error), error == nil else {
            let code = error?[NSAppleScript.errorNumber] as? Int
            return ReadResult(error: code == -1743
                ? "Allow Workshop Wallpaper Bridge to read Music or Spotify in System Settings → Privacy & Security → Automation."
                : "Music information could not be read (Apple Events \(code ?? 0)): \(error?[NSAppleScript.errorMessage] as? String ?? "Unknown error")")
        }
        var result = WallpaperMediaSnapshot(enabled: true)
        let state = descriptor.atIndex(1)?.stringValue ?? "stopped"
        result.state = state == "playing" ? 1 : state == "paused" ? 2 : 0
        guard descriptor.numberOfItems >= 6 else { return ReadResult(snapshot: result) }
        result.title = String((descriptor.atIndex(2)?.stringValue ?? "").prefix(4096))
        result.artist = String((descriptor.atIndex(3)?.stringValue ?? "").prefix(4096))
        result.albumTitle = String((descriptor.atIndex(4)?.stringValue ?? "").prefix(4096))
        let position = descriptor.atIndex(5)?.doubleValue ?? 0
        let duration = (descriptor.atIndex(6)?.doubleValue ?? 0) / (spotify ? 1000 : 1)
        result.duration = duration.isFinite ? min(604800, max(0, duration)) : 0
        result.position = position.isFinite ? min(result.duration, max(0, position)) : 0
        if spotify, let raw = descriptor.atIndex(7)?.stringValue, let url = URL(string: raw), allowedArtworkURL(url) {
            return ReadResult(snapshot: result, artworkURL: url)
        }
        if !spotify, let data = descriptor.atIndex(7)?.data, data.count <= 8 * 1024 * 1024,
           CGImageSourceCreateWithData(data as CFData, nil) != nil { result.artwork = data }
        return ReadResult(snapshot: result)
    }

    nonisolated static func allowedArtworkURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "i.scdn.co" && url.user == nil && url.password == nil
            && (url.port == nil || url.port == 443)
    }
    nonisolated private static func loadArtwork(_ url: URL) async -> Data? {
        guard allowedArtworkURL(url) else { return nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        let session = URLSession(configuration: configuration, delegate: ArtworkRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(from: url)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                  response.expectedContentLength <= 8 * 1024 * 1024 else { return nil }
            var data = Data()
            for try await byte in bytes {
                guard data.count < 8 * 1024 * 1024 else { return nil }
                data.append(byte)
            }
            return CGImageSourceCreateWithData(data as CFData, nil) != nil ? data : nil
        } catch { return nil }
    }
}

private final class ArtworkRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map(MusicMetadataSource.allowedArtworkURL) == true ? request : nil)
    }
}
