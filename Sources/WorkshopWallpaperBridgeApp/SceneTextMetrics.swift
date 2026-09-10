import CoreText
import Foundation

/// Fonts stay in memory; scripts can measure text but cannot open font paths.
final class SceneTextMetrics {
    struct Style {
        let font: CTFont
        let padding: Double
        let maximumWidth: Double?
    }
    private(set) var styles: [Int: Style] = [:]

    func configure(_ configuration: [String: Any]) {
        styles = [:]
        var fonts: [String: CGFont] = [:]
        var totalBytes = 0
        for (path, encoded) in (configuration["fonts"] as? [String: String] ?? [:]).prefix(8) {
            guard let data = Data(base64Encoded: encoded), data.count <= 512 * 1024 else { continue }
            totalBytes += data.count
            guard totalBytes <= 1024 * 1024, let provider = CGDataProvider(data: data as CFData),
                  let font = CGFont(provider) else { continue }
            fonts[path] = font
        }
        for layer in (configuration["layers"] as? [[String: Any]] ?? []).prefix(256) {
            guard let id = layer["id"] as? Int, let metrics = layer["textMetrics"] as? [String: Any] else { continue }
            let size = min(1024, max(1, metrics["fontSize"] as? Double ?? 16))
            let font: CTFont
            if let path = metrics["fontPath"] as? String, let packed = fonts[path] {
                font = CTFontCreateWithGraphicsFont(packed, size, nil, nil)
            } else {
                font = CTFontCreateUIFontForLanguage(.system, size, nil)!
            }
            styles[id] = Style(font: font, padding: min(256, max(0, metrics["padding"] as? Double ?? 0)),
                               maximumWidth: metrics["maximumWidth"] as? Double)
        }
    }

    func measure(id: Int, text: String) -> [Double]? {
        guard let style = styles[id], text.utf8.count <= 65_536 else { return nil }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text,
            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): style.font]))
        let width = CTLineGetTypographicBounds(line, nil, nil, nil) + style.padding * 2
        let height = CTFontGetAscent(style.font) + CTFontGetDescent(style.font) + style.padding * 2
        return [min(max(1, width), style.maximumWidth ?? 1e7), max(1, height)]
    }
}
