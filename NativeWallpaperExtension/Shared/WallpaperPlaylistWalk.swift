import Foundation

/// Shared playlist traversal for the extension and the overlay fallback.
enum WallpaperPlaylistWalk {
    static func makeOrder(
        count: Int,
        mode: WallpaperPlaylistMode,
        avoidingFirst: Int? = nil
    ) -> [Int] {
        guard count > 1, mode == .shuffle else { return Array(0..<count) }
        var order = Array(0..<count).shuffled()
        if let avoidingFirst, order.first == avoidingFirst {
            order.swapAt(0, Int.random(in: 1..<count))
        }
        return order
    }

    /// Move through the current order. A forward shuffle wrap starts a fresh pass and
    /// keeps its first entry different from the wallpaper that just finished.
    static func step(
        order: inout [Int],
        cursor: inout Int,
        offset: Int,
        mode: WallpaperPlaylistMode
    ) {
        guard !order.isEmpty, offset != 0 else { return }
        cursor = min(max(cursor, 0), order.count - 1)

        guard mode == .shuffle, offset > 0 else {
            let delta = offset % order.count
            cursor = ((cursor + delta) % order.count + order.count)
                % order.count
            return
        }

        for _ in 0..<offset {
            if cursor == order.count - 1 {
                order = makeOrder(
                    count: order.count,
                    mode: mode,
                    avoidingFirst: order[cursor]
                )
                cursor = 0
            } else {
                cursor += 1
            }
        }
    }
}
