import CoreGraphics
import Foundation

/// One derived video file advertised by a deployed wallpaper entry.
///
/// Metadata written before renditions existed omits this array. Keeping the descriptor
/// independent of the app's catalog types lets those entries continue to decode unchanged.
struct VideoRendition: Codable {
    let filename: String
    let fps: Int
    let resolution: CGSize
}

enum VideoRenditionSelection {
    private struct Candidate {
        let url: URL
        let fps: Double
        let resolution: CGSize
        let isOriginal: Bool
    }

    /// Picks a file whose decode dimensions and frame rate match the destination and power
    /// policy. Full quality covers every destination pixel when the source has enough pixels.
    /// Reduced and minimal deliberately target fewer pixels as well as a lower frame-rate cap.
    static func select(
        originalURL: URL,
        originalFPS: Double,
        originalResolution: CGSize,
        renditions: [VideoRendition],
        destinationPixelSize: CGSize,
        policy: PlaybackPolicy,
        renditionURL: (VideoRendition) -> URL
    ) -> URL {
        let usableRenditions = renditions.filter {
            $0.fps > 0 && $0.resolution.width > 0 && $0.resolution.height > 0
        }
        guard !usableRenditions.isEmpty else { return originalURL }

        let advertisedNormalFPS = max(
            originalFPS,
            Double(usableRenditions.map(\.fps).max() ?? 0)
        )
        let normalFPS = advertisedNormalFPS > 0 ? advertisedNormalFPS : 30
        let effectivePolicy = policy == .paused ? PlaybackPolicy.full : policy
        let fpsCeiling: Double
        let resolutionScale: CGFloat
        switch effectivePolicy {
        case .full, .paused:
            fpsCeiling = normalFPS
            resolutionScale = 1
        case .reduced:
            fpsCeiling = min(normalFPS, 30)
            resolutionScale = 0.625
        case .minimal:
            fpsCeiling = min(normalFPS, 15)
            resolutionScale = 0.5
        }

        var candidates = usableRenditions.map {
            Candidate(
                url: renditionURL($0),
                fps: Double($0.fps),
                resolution: $0.resolution,
                isOriginal: false
            )
        }
        let originalCandidateFPS = originalFPS > 0 ? originalFPS : normalFPS
        candidates.append(Candidate(
            url: originalURL,
            fps: originalCandidateFPS,
            resolution: originalResolution,
            isOriginal: true
        ))

        // Prefer the highest advertised rate at or below the tier's ceiling. Integer
        // metadata rounds rates such as 29.97 to 30, so allow a small comparison margin.
        let underCeiling = candidates.filter { $0.fps <= fpsCeiling + 0.5 }
        let ratePool = underCeiling.isEmpty ? candidates : underCeiling
        guard let selectedFPS = ratePool.map(\.fps).max() else { return originalURL }
        let matchingRate = ratePool.filter { abs($0.fps - selectedFPS) < 0.6 }

        let destination = CGSize(
            width: destinationPixelSize.width.isFinite
                ? max(1, destinationPixelSize.width * resolutionScale)
                : 1,
            height: destinationPixelSize.height.isFinite
                ? max(1, destinationPixelSize.height * resolutionScale)
                : 1
        )
        let covering = matchingRate.filter {
            $0.resolution.width + 1 >= destination.width
                && $0.resolution.height + 1 >= destination.height
        }
        let sizePool = covering.isEmpty ? matchingRate : covering
        guard let chosen = sizePool.min(by: { lhs, rhs in
            let lhsArea = lhs.resolution.width * lhs.resolution.height
            let rhsArea = rhs.resolution.width * rhs.resolution.height
            if covering.isEmpty, lhsArea != rhsArea {
                return lhsArea > rhsArea
            }
            if lhsArea != rhsArea { return lhsArea < rhsArea }
            // An equal derived file exists to replace a non-HEVC original. Prefer it or
            // the deployment paid for an advertised rendition that selection never uses.
            if lhs.isOriginal != rhs.isOriginal { return !lhs.isOriginal }
            return lhs.url.path < rhs.url.path
        }) else {
            return originalURL
        }
        return chosen.url
    }
}
