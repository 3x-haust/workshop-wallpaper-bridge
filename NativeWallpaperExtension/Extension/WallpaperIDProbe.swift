import Foundation

/// The `WallpaperID` UUID inside a WallpaperIDXPC (`box.rawValue.id`), or nil. Returns the
/// first UUID found in the Mirror tree.
func extractWallpaperUUID(fromID id: Any?) -> UUID? {
    extractWallpaperUUIDs(fromID: id).first
}

/// Every UUID carried by a WallpaperKit identifier. Snapshot requests can
/// contain both a transient surface UUID and the permanent choice
/// configuration UUID, so callers that need a display fallback must inspect
/// all candidates rather than assuming the first one is sufficient.
func extractWallpaperUUIDs(fromID id: Any?) -> [UUID] {
    guard let id else { return [] }
    var result: [UUID] = []
    var seen = Set<UUID>()
    collectUUIDs(id, depth: 0, result: &result, seen: &seen)
    return result
}

private func collectUUIDs(
    _ value: Any,
    depth: Int,
    result: inout [UUID],
    seen: inout Set<UUID>
) {
    guard depth < 8 else { return }
    if let uuid = value as? UUID {
        if seen.insert(uuid).inserted {
            result.append(uuid)
        }
        return
    }
    for child in Mirror(reflecting: value).children {
        collectUUIDs(
            child.value,
            depth: depth + 1,
            result: &result,
            seen: &seen
        )
    }
}
