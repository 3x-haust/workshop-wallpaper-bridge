import Foundation

struct WorkshopSearchFilters: Codable, Equatable, Sendable {
    enum Selection: String, CaseIterable, Sendable {
        case neutral, include, exclude

        var localizationKey: String { "workshop.filter.\(rawValue)" }
    }

    enum Category: String, CaseIterable, Identifiable, Sendable {
        case miscellaneous, type, ageRating, genre, resolution

        var id: String { rawValue }
        var localizationKey: String { "workshop.filter.category.\(rawValue)" }

        // Steam's readytouse_tags: https://steamcommunity.com/workshop/browse/?appid=431960
        var tags: [String] {
            switch self {
            case .miscellaneous:
                return ["Approved", "Audio responsive", "3D", "Customizable", "Puppet Warp", "HDR",
                        "Media Integration", "User Shortcut", "Video Texture", "Asset Pack"]
            case .type:
                return ["Scene", "Video", "Application", "Web"]
            case .ageRating:
                return ["Everyone", "Questionable", "Mature"]
            case .genre:
                return ["Abstract", "Animal", "Anime", "Cartoon", "CGI", "Cyberpunk", "Fantasy", "Game",
                        "Girls", "Guys", "Landscape", "Medieval", "Memes", "MMD", "Music", "Nature",
                        "Pixel art", "Relaxing", "Retro", "Sci-Fi", "Sports", "Technology", "Television",
                        "Vehicle", "Unspecified"]
            case .resolution:
                return ["Standard Definition", "1280 x 720", "1366 x 768", "1920 x 1080", "2560 x 1440",
                        "3840 x 2160", "Ultrawide Standard Definition", "Ultrawide 2560 x 1080",
                        "Ultrawide 3440 x 1440", "Dual Standard Definition", "Dual 3840 x 1080",
                        "Dual 5120 x 1440", "Dual 7680 x 2160", "Triple Standard Definition", "Triple 4096 x 768",
                        "Triple 5760 x 1080", "Triple 7680 x 1440", "Triple 11520 x 2160",
                        "Portrait Standard Definition", "Portrait 720 x 1280", "Portrait 1080 x 1920",
                        "Portrait 1440 x 2560", "Portrait 2160 x 3840", "Other resolution", "Dynamic resolution"]
            }
        }
    }

    var includedTags: Set<String> = ["Everyone"]
    var excludedTags: Set<String> = ["Questionable", "Mature"]

    init() {}

    private enum CodingKeys: String, CodingKey { case includedTags, excludedTags }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        includedTags = try container.decodeIfPresent(Set<String>.self, forKey: .includedTags) ?? ["Everyone"]
        excludedTags = try container.decodeIfPresent(Set<String>.self, forKey: .excludedTags) ?? ["Questionable", "Mature"]
        self = normalized()
    }

    static var allTags: Set<String> { Set(Category.allCases.flatMap(\.tags)) }

    static func localizationKey(for tag: String) -> String {
        "workshop.filter.tag." + tag.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    func normalized() -> Self {
        var result = self
        result.excludedTags.formIntersection(Self.allTags)
        result.includedTags.formIntersection(Self.allTags)
        // Preserve explicit exclusions if persisted or externally assigned sets overlap.
        result.includedTags.subtract(result.excludedTags)
        return result
    }

    func selection(for tag: String) -> Selection {
        if excludedTags.contains(tag) { return .exclude }
        return includedTags.contains(tag) ? .include : .neutral
    }

    mutating func setSelection(_ selection: Selection, for tag: String) {
        guard Self.allTags.contains(tag) else { return }
        includedTags.remove(tag)
        excludedTags.remove(tag)
        switch selection {
        case .include: includedTags.insert(tag)
        case .exclude: excludedTags.insert(tag)
        case .neutral: break
        }
    }

    mutating func reset() { self = Self() }

    var selectedCount: Int { normalized().includedTags.count + normalized().excludedTags.count }

    var ageSummaryKey: String {
        let value = normalized()
        let ages = Set(Category.ageRating.tags)
        if value.includedTags.intersection(ages) == ["Everyone"],
           value.excludedTags.isSuperset(of: ["Questionable", "Mature"]) {
            return "workshop.filter.age.everyoneOnly"
        }
        if value.includedTags.isDisjoint(with: ages), value.excludedTags.isDisjoint(with: ages) {
            return "workshop.filter.age.any"
        }
        return "workshop.filter.age.custom"
    }

    /// Each inner group is OR; groups are AND. Miscellaneous features are individually required.
    var tagGroups: [[String]] {
        let included = normalized().includedTags
        return Category.allCases.flatMap { category -> [[String]] in
            let tags = category.tags.filter { included.contains($0) }.sorted()
            if category == .miscellaneous { return tags.map { [$0] } }
            return tags.isEmpty ? [] : [tags]
        }
    }
}
