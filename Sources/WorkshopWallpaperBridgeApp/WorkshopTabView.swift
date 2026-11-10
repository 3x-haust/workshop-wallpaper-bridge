import AppKit
import SwiftUI
import WorkshopWallpaperCore

struct WorkshopTabView: View {
    @ObservedObject var model: AppViewModel
    @ObservedObject var workshop: WorkshopViewModel
    @Binding var showsAccount: Bool
    @State private var selectedItemID: String?
    @State private var showsDetail = false
    @State private var showsLargePreview = false
    @State private var largeThumbnails = false
    @State private var showsFilters = false
    private var mutationsDisabled: Bool { workshop.isBusy || model.isWorking }

    private var inspectedDownload: WorkshopDownload? {
        guard let download = workshop.selectedDownload else { return nil }
        return selectedItemID == download.id ? download : nil
    }

    private var inspectedItem: WorkshopItem? {
        if let detail = workshop.detail, selectedItemID == nil || detail.id == selectedItemID { return detail }
        return workshop.items.first { $0.id == selectedItemID }
    }

    private var previewURL: URL? {
        if let download = inspectedDownload {
            let asset = workshop.selectedAsset ?? model.libraryAssets.first { $0.id == download.id }
            if let thumbnail = asset?.thumbnail { return URL(filePath: thumbnail) }
            if asset?.kind == .image, let entrypoint = asset?.entrypoint { return URL(filePath: entrypoint) }
        }
        guard let value = inspectedItem?.previewURL, let url = URL(string: value),
              url.scheme?.lowercased() == "https", url.host != nil, url.user == nil, url.password == nil else { return nil }
        return url
    }

    private var inspectedTitle: String? { inspectedDownload?.title ?? inspectedItem?.title }

    var body: some View {
        GeometryReader { geometry in
            let hasInspector = geometry.size.width >= 800
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    heading
                    searchTools
                    searchGrid(compact: !hasInspector)
                    pagination
                    operationStatus
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if hasInspector {
                    Rectangle().fill(BrowserPalette.border).frame(width: 1)
                    inspector.frame(width: 300)
                }
            }
            .sheet(isPresented: $showsDetail) {
                VStack(spacing: 0) {
                    HStack {
                        Spacer()
                        Button(model.L("common.close")) { showsDetail = false }
                            .keyboardShortcut(.cancelAction)
                    }.padding(16)
                    inspector
                }
                .frame(width: 420, height: 540)
                .background(BrowserPalette.sidebar)
            }
        }
        .background(BrowserPalette.background)
        .sheet(isPresented: $showsFilters) {
            WorkshopFiltersView(model: model, filters: workshop.filters) { filters in
                workshop.updateFilters(filters)
            }
        }
        .sheet(isPresented: $showsLargePreview) {
            VStack(spacing: 14) {
                HStack {
                    Text(inspectedTitle ?? model.L("workshop.detail.preview")).font(.headline).lineLimit(2)
                    Spacer()
                    Button(model.L("common.close")) { showsLargePreview = false }
                        .keyboardShortcut(.cancelAction)
                }
                BrowserThumbnail(url: previewURL, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(20).frame(minWidth: 540, idealWidth: 800, minHeight: 380, idealHeight: 560)
            .background(BrowserPalette.background)
        }
        .task(id: workshop.isAuthenticated) {
            if workshop.isAuthenticated, workshop.items.isEmpty, !workshop.isBusy { workshop.search() }
        }
    }

    private var heading: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 6) {
                Text("STEAM WORKSHOP").font(.system(size: 10, weight: .semibold))
                    .tracking(1).foregroundStyle(BrowserPalette.secondary)
                Text(model.L("workshop.browser.explore"))
                    .font(.system(size: 25, weight: .semibold))
            }
            Spacer()
            Button { largeThumbnails.toggle() } label: {
                Image(systemName: largeThumbnails ? "square.grid.3x3" : "square.grid.2x2")
            }
            .buttonStyle(.plain).foregroundStyle(BrowserPalette.secondary)
            .accessibilityLabel(model.L("workshop.browser.thumbnailSize"))
            .help(model.L("workshop.browser.thumbnailSize"))
        }
        .padding(.horizontal, 22).padding(.top, 24).padding(.bottom, 18)
    }

    private var searchTools: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(BrowserPalette.secondary)
                TextField(model.L("workshop.search.placeholder"), text: $workshop.query)
                    .textFieldStyle(.plain)
                    .onSubmit { if !mutationsDisabled, workshop.isAuthenticated { workshop.search() } }
                Button(model.L("workshop.search.button")) { workshop.search() }.buttonStyle(.plain)
                    .foregroundStyle(BrowserPalette.accent)
            }
            .padding(10).background(BrowserPalette.surface, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(BrowserPalette.border, lineWidth: 1))
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { filterControls }
                VStack(alignment: .leading, spacing: 8) { filterControls }
            }
            Text(model.L(workshop.filters.ageSummaryKey))
                .font(.caption).foregroundStyle(BrowserPalette.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 22).padding(.bottom, 16)
        .disabled(mutationsDisabled || !workshop.isAuthenticated)
    }

    @ViewBuilder
    private var filterControls: some View {
        Button { showsFilters = true } label: {
            Label(String(format: model.L("workshop.filter.button"), workshop.filters.selectedCount), systemImage: "line.3.horizontal.decrease.circle")
        }
        .accessibilityLabel(model.L("workshop.filter.title"))
        .accessibilityValue(String(format: model.L("workshop.filter.count"), workshop.filters.selectedCount))
        Picker(model.L("workshop.browser.sort"), selection: $workshop.sort) {
            Text(model.L("workshop.sort.popular")).tag("popular")
            Text(model.L("workshop.sort.recent")).tag("recent")
            Text(model.L("workshop.sort.rated")).tag("rated")
        }
        .onChange(of: workshop.sort) { _, _ in workshop.search(page: 1) }
    }

    private func searchGrid(compact: Bool) -> some View {
        ScrollViewReader { proxy in
            searchResults(compact: compact)
                .onChange(of: workshop.page) { _, _ in
                    proxy.scrollTo("searchResultsTop", anchor: .top)
                }
        }
    }

    private func searchResults(compact: Bool) -> some View {
        Group {
            if workshop.items.isEmpty {
                VStack(spacing: 16) {
                    BrowserEmptyState(
                        symbol: workshop.isAuthenticated ? "magnifyingglass" : "safari",
                        title: model.L(workshop.isAuthenticated ? "workshop.browser.noResults" : "workshop.browser.welcome"),
                        message: model.L(workshop.isAuthenticated ? "workshop.browser.trySearch" : "workshop.browser.signInDescription")
                    )
                    if !workshop.isAuthenticated {
                        Button(model.L("workshop.browser.connect")) { showsAccount = true }
                            .buttonStyle(.borderedProminent).padding(.bottom, 40)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: largeThumbnails ? 210 : 155), spacing: 13)], spacing: 18) {
                        ForEach(workshop.items) { item in
                            thumbnailCard(title: item.title, subtitle: item.kind.map { model.L("workshop.kind.\($0)") } ?? model.L("workshop.detail.unknown"),
                                          url: Self.remotePreview(item.previewURL), selected: selectedItemID == item.id,
                                          downloaded: isDownloaded(item.id)) {
                                selectedItemID = item.id
                                if isDownloaded(item.id) { workshop.selectDownload(item.id) }
                                else { workshop.showDetails(item) }
                                if compact { showsDetail = true }
                            }
                            .disabled(mutationsDisabled)
                        }
                    }
                    .padding(.horizontal, 22).padding(.bottom, 20)
                    .id("searchResultsTop")
                }
            }
        }
    }

    private func thumbnailCard(title: String, subtitle: String, url: URL?, selected: Bool, downloaded: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                GeometryReader { geometry in
                    BrowserThumbnail(url: url)
                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                }
                .aspectRatio(1.5, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(selected ? BrowserPalette.accent : .clear, lineWidth: 2))
                .overlay(alignment: .topTrailing) {
                    if downloaded {
                        Image(systemName: "arrow.down.circle.fill").foregroundStyle(BrowserPalette.accent)
                            .padding(7).shadow(color: .black.opacity(0.7), radius: 3)
                            .help(model.L("workshop.download.badge"))
                    }
                }
                Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1).padding(.top, 2)
                Text(subtitle).font(.system(size: 10)).foregroundStyle(BrowserPalette.secondary).lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(subtitle)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(title)
    }

    private var pagination: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button { workshop.search(page: workshop.page - 1) } label: {
                    Image(systemName: "chevron.left").frame(width: 28, height: 28)
                }
                .disabled(workshop.page <= 1).accessibilityLabel(model.L("workshop.page.previous"))
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 4) { pageButtons }
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 4) { pageButtons }
                }
                Button { workshop.search(page: workshop.page + 1) } label: {
                    Image(systemName: "chevron.right").frame(width: 28, height: 28)
                }
                .disabled(!workshop.hasNextPage).accessibilityLabel(model.L("workshop.page.next"))
                Spacer(minLength: 0)
            }
            Text(String(format: model.L("workshop.page.summary"), workshop.page, workshop.total))
                .font(.caption).foregroundStyle(BrowserPalette.secondary)
        }
        .buttonStyle(.plain).padding(.horizontal, 22).padding(.vertical, 10)
        .disabled(mutationsDisabled || !workshop.isAuthenticated)
    }

    private var pageButtons: some View {
        ForEach(workshop.pageNumbers, id: \.self) { page in
            Button {
                if page != workshop.page { workshop.search(page: page) }
            } label: {
                Text(String(page))
                    .font(.system(size: 12, weight: page == workshop.page ? .semibold : .regular).monospacedDigit())
                    .padding(.horizontal, 8).frame(minWidth: 32, minHeight: 28)
                    .fixedSize(horizontal: true, vertical: false)
                    .foregroundStyle(page == workshop.page ? BrowserPalette.text : BrowserPalette.secondary)
                    .background(page == workshop.page ? BrowserPalette.selection : .clear, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(page == workshop.page ? BrowserPalette.accent : .clear, lineWidth: 1))
            }
            .accessibilityLabel(String(format: model.L("workshop.page.button"), page))
            .accessibilityAddTraits(page == workshop.page ? .isSelected : [])
        }
    }

    private var inspector: some View {
        Group {
            if let title = inspectedTitle {
                ScrollView {
                    VStack(alignment: .leading, spacing: 15) {
                        HStack {
                            BrowserSectionLabel(title: model.L("workshop.detail.preview"))
                            Spacer()
                            HelpPopoverButton(title: model.L("workshop.detail.preview"), message: model.L("workshop.compatibility.help"))
                        }
                        BrowserThumbnail(url: previewURL, contentMode: .fit)
                            .frame(height: 180).frame(maxWidth: .infinity)
                            .background(.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 7))
                            .overlay(alignment: .bottomTrailing) {
                                Button { showsLargePreview = true } label: {
                                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                                        .padding(7).background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 5))
                                }
                                .buttonStyle(.plain).padding(8)
                                .accessibilityLabel(model.L("workshop.browser.expandPreview"))
                                .disabled(previewURL == nil)
                            }
                        Text(title).font(.system(size: 20, weight: .semibold)).textSelection(.enabled)
                        if let download = inspectedDownload {
                            downloadedDetails(download)
                        } else if let item = inspectedItem {
                            remoteDetails(item)
                        }
                    }
                    .padding(20)
                }
            } else {
                BrowserEmptyState(symbol: "photo", title: model.L("workshop.browser.selectTitle"), message: model.L("workshop.browser.selectDescription"))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BrowserPalette.sidebar)
    }

    private func remoteDetails(_ item: WorkshopItem) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                workshop.download(item)
            } label: {
                Label(model.L(isDownloaded(item.id) ? "workshop.browser.apply" : "workshop.browser.downloadAndApply"), systemImage: isDownloaded(item.id) ? "play.fill" : "arrow.down.to.line")
                    .frame(maxWidth: .infinity).padding(.vertical, 5)
            }
            .buttonStyle(.borderedProminent)
            .disabled(mutationsDisabled || (!workshop.isAuthenticated && !isDownloaded(item.id)))
            .help(model.L("workshop.browser.automaticallySaved"))
            if !workshop.isAuthenticated, !isDownloaded(item.id) {
                Button(model.L("workshop.browser.connect")) { showsAccount = true }.buttonStyle(.link)
            }
            Divider()
            detailRow(model.L("workshop.detail.kind"), value: item.kind.map { model.L("workshop.kind.\($0)") } ?? model.L("workshop.detail.unknown"))
            if let size = item.size { detailRow(model.L("workshop.detail.size"), value: Self.byteCount(size)) }
            detailRow("ID", value: item.id)
            if let creatorID = item.creatorID, let creator = UInt64(creatorID), creator > 0,
               let url = URL(string: "https://steamcommunity.com/profiles/\(creator)/myworkshopfiles/?appid=431960") {
                Link(destination: url) {
                    Label(model.L("workshop.browser.creatorItems"), systemImage: "person.crop.circle")
                }.font(.caption)
            }
            if let tags = item.tags, !tags.isEmpty {
                Text(tags.prefix(6).joined(separator: " · "))
                    .font(.caption).foregroundStyle(BrowserPalette.secondary)
            }
            if !item.description.isEmpty {
                Text(item.description).font(.callout).foregroundStyle(BrowserPalette.secondary).textSelection(.enabled)
            }
            if let url = URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(item.id)") {
                Link(destination: url) { Label(model.L("workshop.browser.openSteam"), systemImage: "arrow.up.right.square") }.font(.caption)
            }
        }
    }

    private func downloadedDetails(_ download: WorkshopDownload) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let asset = workshop.selectedAsset {
                Text(model.L("workshop.support.\(asset.supportStatus.rawValue)"))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(asset.supportStatus == .playable ? BrowserPalette.accent : .orange)
                detailRow(model.L("workshop.detail.kind"), value: model.L("workshop.kind.\(asset.kind.rawValue)"))
                ForEach(Array(asset.issues.enumerated()), id: \.offset) { _, issue in
                    Text(issue.message).font(.caption).foregroundStyle(BrowserPalette.secondary)
                }
                if asset.supportStatus == .needsConversion || workshop.libraryAsset?.supportStatus == .needsConversion {
                    Text(model.L("workshop.convert.help")).font(.caption).foregroundStyle(BrowserPalette.secondary)
                }
            }
            Button { workshop.selectDownload(download.id) } label: {
                Label(model.L("workshop.browser.apply"), systemImage: "play.fill").frame(maxWidth: .infinity).padding(.vertical, 5)
            }
            .buttonStyle(.borderedProminent)
            .disabled(mutationsDisabled || workshop.libraryAsset?.supportStatus != .playable)
        }
    }

    private func detailRow(_ title: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(title).foregroundStyle(BrowserPalette.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing)
        }.font(.caption)
    }

    private var operationStatus: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 8) {
                if workshop.isBusy { ProgressView().controlSize(.small) }
                Text(model.L(workshop.statusKey)).font(.caption).foregroundStyle(BrowserPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 5)
                if workshop.canCancel {
                    Button(model.L("common.cancel")) { workshop.cancel() }
                        .help(model.L(workshop.operation == "preparing" ? "workshop.prepare.cancel.help" : "workshop.cancel.help"))
                }
                if workshop.statusKey == "workshop.error.prepare", let download = workshop.selectedDownload {
                    Button(model.L("workshop.prepare.retry")) { workshop.selectDownload(download.id) }
                        .disabled(mutationsDisabled)
                }
                if workshop.retryItem != nil {
                    Button(model.L("workshop.download.retry")) { workshop.retryDownload() }
                        .disabled(mutationsDisabled || !workshop.isAuthenticated)
                }
            }
            if workshop.operation == "preparing" {
                if let progress = workshop.preparationProgress, progress.isFinite {
                    let fraction = min(max(progress, 0), 1)
                    HStack {
                        ProgressView(value: fraction)
                        Text(fraction, format: .percent.precision(.fractionLength(0)))
                            .font(.caption.monospacedDigit()).foregroundStyle(BrowserPalette.secondary)
                    }
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
            }
            if workshop.operation == "download" {
                if workshop.totalBytes > 0 {
                    ProgressView(value: Double(min(workshop.completedBytes, workshop.totalBytes)), total: Double(workshop.totalBytes))
                }
                Text("\(Self.byteCount(workshop.completedBytes)) / \(Self.byteCount(workshop.totalBytes))")
                    .font(.caption.monospacedDigit()).foregroundStyle(BrowserPalette.secondary)
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 12)
        .background(BrowserPalette.surface)
    }

    private func isDownloaded(_ id: String) -> Bool { workshop.downloads.contains { $0.id == id } }

    private static func remotePreview(_ value: String?) -> URL? {
        guard let value, let url = URL(string: value), url.scheme?.lowercased() == "https",
              url.host != nil, url.user == nil, url.password == nil else { return nil }
        return url
    }

    private static func byteCount(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }
}
