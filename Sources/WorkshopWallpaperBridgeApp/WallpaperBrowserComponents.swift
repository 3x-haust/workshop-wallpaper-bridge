import AppKit
import SwiftUI

/// Shared visual language for the library and Workshop browser.
enum BrowserPalette {
    static let background = Color(red: 20 / 255, green: 22 / 255, blue: 25 / 255)
    static let sidebar = Color(red: 27 / 255, green: 29 / 255, blue: 33 / 255)
    static let surface = Color(red: 32 / 255, green: 35 / 255, blue: 40 / 255)
    static let raised = Color(red: 40 / 255, green: 44 / 255, blue: 50 / 255)
    static let border = Color(red: 48 / 255, green: 52 / 255, blue: 58 / 255)
    static let text = Color(red: 239 / 255, green: 241 / 255, blue: 244 / 255)
    static let secondary = Color(red: 156 / 255, green: 163 / 255, blue: 174 / 255)
    static let accent = Color(red: 121 / 255, green: 173 / 255, blue: 255 / 255)
    static let selection = Color(red: 38 / 255, green: 59 / 255, blue: 89 / 255)
}

struct BrowserThumbnail: View {
    let url: URL?
    var contentMode: ContentMode = .fill

    var body: some View {
        Group {
            if let url, url.isFileURL, let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: contentMode)
            } else if let url, url.scheme?.lowercased() == "https" {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: contentMode)
                    } else {
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .accessibilityHidden(true)
    }

    private var placeholder: some View {
        Rectangle().fill(BrowserPalette.surface)
            .overlay {
                Image(systemName: "photo")
                    .font(.system(size: 27, weight: .light))
                    .foregroundStyle(BrowserPalette.secondary)
            }
    }
}

struct BrowserEmptyState: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(BrowserPalette.secondary)
            Text(title).font(.headline).foregroundStyle(BrowserPalette.text)
            Text(message).font(.callout).foregroundStyle(BrowserPalette.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 330)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct BrowserSectionLabel: View {
    let title: String

    var body: some View {
        Text(title).font(.caption.weight(.semibold))
            .foregroundStyle(BrowserPalette.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
