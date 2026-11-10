import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI
import WorkshopWallpaperCore

struct WorkshopTabView: View {
    @ObservedObject var model: AppViewModel
    @ObservedObject var workshop: WorkshopViewModel
    @State private var username = ""
    @State private var password = ""
    @State private var guardCode = ""
    @State private var passwordLogin = false
    @State private var showsDownloads = false
    @State private var confirmsAuthenticationDeletion = false

    private var mutationsDisabled: Bool { workshop.isBusy || model.isWorking }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    accountSection
                    Divider()
                    Picker(model.L("workshop.browse"), selection: $showsDownloads) {
                        Text(model.L("workshop.search.title")).tag(false)
                        Text("\(model.L("workshop.downloads.title")) (\(workshop.downloads.count))").tag(true)
                    }
                    .pickerStyle(.segmented)
                    if showsDownloads {
                        downloadsSection
                    } else {
                        searchSection
                    }
                }
            }
            Divider()
            operationStatus
        }
        .padding()
        .confirmationDialog(
            model.L("workshop.credentials.delete.title"),
            isPresented: $confirmsAuthenticationDeletion,
            titleVisibility: .visible
        ) {
            Button(model.L("workshop.credentials.delete"), role: .destructive) {
                workshop.deleteSavedAuthentication()
            }
            .disabled(mutationsDisabled)
            Button(model.L("common.cancel"), role: .cancel) {}
        } message: {
            Text(model.L("workshop.credentials.delete.message"))
        }
        .confirmationDialog(
            model.L("workshop.download.remove.title"),
            isPresented: Binding(
                get: { workshop.pendingRemoval != nil },
                set: { if !$0 { workshop.pendingRemoval = nil } }
            ),
            titleVisibility: .visible,
            presenting: workshop.pendingRemoval
        ) { download in
            Button(model.L("workshop.download.remove"), role: .destructive) {
                workshop.removeDownloaded(download)
            }
            .disabled(mutationsDisabled)
            Button(model.L("common.cancel"), role: .cancel) { workshop.pendingRemoval = nil }
        } message: { download in
            Text(String(format: model.L("workshop.download.remove.message"), download.title))
        }
        .onChange(of: workshop.authPrompt) { _, _ in guardCode = "" }
        .onChange(of: workshop.operation) { _, _ in
            password = ""
            guardCode = ""
        }
        .onDisappear {
            password = ""
            guardCode = ""
        }
    }

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(workshop.account ?? model.L("workshop.account.disconnected"), systemImage: "person.crop.circle")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                if workshop.isAuthenticated {
                    Button(model.L("workshop.logout")) { workshop.logout() }
                        .help(model.L("workshop.logout.help"))
                        .disabled(mutationsDisabled)
                }
                if workshop.hasStoredAuthentication {
                    Button(model.L("workshop.credentials.delete")) { confirmsAuthenticationDeletion = true }
                        .disabled(mutationsDisabled)
                }
            }
            HStack(alignment: .top, spacing: 6) {
                Text(model.L(workshop.hasSavedSession ? "workshop.credentials.saved" : "workshop.credentials.automatic"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HelpPopoverButton(
                    title: model.L("workshop.credentials.title"),
                    message: model.L("workshop.credentials.help")
                )
                .accessibilityLabel(model.L("workshop.credentials.title"))
            }
            if !workshop.isAuthenticated {
                if workshop.hasSavedSession {
                    Button(model.L("workshop.resume")) { workshop.resume() }
                        .disabled(mutationsDisabled)
                }
                Picker(model.L("workshop.login.method"), selection: $passwordLogin) {
                    Text(model.L("workshop.login.qr.method")).tag(false)
                    Text(model.L("workshop.login.password.method")).tag(true)
                }
                .pickerStyle(.segmented)
                .disabled(mutationsDisabled)
                if passwordLogin {
                    passwordForm
                } else {
                    Button(model.L("workshop.login.qr")) { workshop.loginQR() }
                        .disabled(mutationsDisabled)
                }
                if let qrURL = workshop.qrURL {
                    qrCode(qrURL)
                }
                authenticationPrompt
            }
        }
    }

    private var passwordForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.L("workshop.login.username")).font(.caption)
                    TextField(model.L("workshop.login.username"), text: $username)
                        .textContentType(.username)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.L("workshop.login.password")).font(.caption)
                    SecureField(model.L("workshop.login.password"), text: $password)
                        .textContentType(.password)
                        .onSubmit(loginWithPassword)
                }
                Button(model.L("workshop.login.submit"), action: loginWithPassword)
                    .disabled(username.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty)
            }
        }
        .disabled(mutationsDisabled)
    }

    private func loginWithPassword() {
        guard !mutationsDisabled else { return }
        workshop.login(username: username, password: password)
        password = ""
    }

    @ViewBuilder
    private var authenticationPrompt: some View {
        if let prompt = workshop.authPrompt {
            if prompt == "emailCode" || prompt == "twoFactor" {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.L(prompt == "emailCode" ? "workshop.auth.emailCode" : "workshop.auth.twoFactor"))
                        .font(.caption)
                    HStack {
                        SecureField(model.L("workshop.auth.code"), text: $guardCode)
                            .onSubmit(submitGuard)
                        Button(model.L("workshop.auth.submit"), action: submitGuard)
                            .disabled(guardCode.isEmpty || !workshop.canCancel)
                    }
                }
            } else if prompt == "mobileApproval" {
                Text(model.L("workshop.auth.mobileApproval"))
                    .font(.callout)
            }
        }
    }

    private func submitGuard() {
        guard workshop.canCancel else { return }
        workshop.submitGuard(guardCode)
        guardCode = ""
    }

    private func qrCode(_ value: String) -> some View {
        HStack(alignment: .center, spacing: 12) {
            if let image = Self.qrImage(value) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 160, height: 160)
                    .padding(12)
                    .background(.white)
                    .accessibilityLabel(model.L("workshop.auth.qr.image"))
            } else {
                Text(model.L("workshop.auth.qr.unavailable"))
            }
            Text(model.L("workshop.auth.scan"))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private static func qrImage(_ value: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    private var searchSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField(model.L("workshop.search.placeholder"), text: $workshop.query)
                    .onSubmit { if !mutationsDisabled { workshop.search() } }
                Button(model.L("workshop.search.button")) { workshop.search() }
            }
            .disabled(mutationsDisabled || !workshop.isAuthenticated)
            List(selection: Binding<String?>(
                get: { workshop.detail?.id },
                set: { id in
                    guard !mutationsDisabled, let item = workshop.items.first(where: { $0.id == id }) else { return }
                    workshop.showDetails(item)
                }
            )) {
                ForEach(workshop.items) { item in
                    HStack {
                        Text(item.title).lineLimit(2)
                        Spacer()
                        if workshop.downloads.contains(where: { $0.id == item.id }) {
                            Text(model.L("workshop.download.badge"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tag(item.id)
                }
            }
            .frame(height: 150)
            .disabled(mutationsDisabled || !workshop.isAuthenticated)
            .overlay {
                if workshop.items.isEmpty {
                    Text(model.L("workshop.search.placeholder.empty"))
                        .foregroundStyle(.secondary)
                        .allowsHitTesting(false)
                }
            }
            HStack {
                Button(model.L("workshop.page.previous")) { workshop.search(page: workshop.page - 1) }
                    .disabled(workshop.page <= 1)
                Text(String(format: model.L("workshop.page.summary"), workshop.page, workshop.total))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(model.L("workshop.page.next")) { workshop.search(page: workshop.page + 1) }
                    .disabled(!workshop.hasNextPage)
                Spacer()
            }
            .disabled(mutationsDisabled || !workshop.isAuthenticated)
            if let detail = workshop.detail {
                detailSection(detail)
            }
        }
    }

    private func detailSection(_ item: WorkshopItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.title).font(.headline)
            HStack(alignment: .top, spacing: 12) {
                if let value = item.previewURL, let url = URL(string: value),
                   url.scheme?.lowercased() == "https", url.host != nil,
                   url.user == nil, url.password == nil {
                    AsyncImage(url: url) { image in
                        image.resizable().scaledToFit()
                    } placeholder: {
                        Image(systemName: "photo").foregroundStyle(.secondary)
                    }
                    .frame(width: 144, height: 88)
                    .accessibilityLabel(model.L("workshop.detail.preview"))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(model.L("workshop.detail.kind")): \(item.kind ?? model.L("workshop.detail.unknown"))")
                    if let size = item.size {
                        Text("\(model.L("workshop.detail.size")): \(Self.byteCount(size))")
                    }
                    Text("ID: \(item.id)").foregroundStyle(.secondary)
                }
                .font(.caption)
            }
            Text(item.description).font(.callout).textSelection(.enabled)
            Button(model.L(isDownloaded(item.id) ? "workshop.download.show" : "workshop.download.button")) {
                workshop.download(item)
                if isDownloaded(item.id) { showsDownloads = true }
            }
            .disabled(mutationsDisabled || !workshop.isAuthenticated)
            compatibilityNotice
        }
    }

    private var downloadsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            List(selection: Binding<String?>(
                get: { workshop.selectedDownloadID },
                set: { if !mutationsDisabled, let id = $0 { workshop.selectDownload(id) } }
            )) {
                ForEach(workshop.downloads) { download in
                    Text(download.title).lineLimit(2).tag(download.id)
                }
            }
            .frame(height: 150)
            .disabled(mutationsDisabled)
            .overlay {
                if workshop.downloads.isEmpty {
                    Text(model.L("workshop.downloads.empty"))
                        .foregroundStyle(.secondary)
                        .allowsHitTesting(false)
                }
            }
            if let selected = workshop.selectedDownload {
                Text(selected.title).font(.headline)
                if let asset = workshop.selectedAsset {
                    Text("\(model.L("workshop.detail.kind")): \(asset.kind.rawValue) · \(model.L("workshop.support.\(asset.supportStatus.rawValue)"))")
                        .font(.callout)
                    ForEach(Array(asset.issues.enumerated()), id: \.offset) { _, issue in
                        Text(issue.message).font(.caption).foregroundStyle(.secondary)
                    }
                    if asset.supportStatus == .needsConversion || workshop.libraryAsset?.supportStatus == .needsConversion {
                        Text(model.L("workshop.convert.help")).font(.caption)
                    }
                }
                Text(model.L(workshop.libraryAsset == nil ? "workshop.library.absent" : "workshop.library.exists"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ViewThatFits(in: .horizontal) {
                    HStack { downloadActions }
                    VStack(alignment: .leading) { downloadActions }
                }
                .disabled(mutationsDisabled)
            }
            compatibilityNotice
        }
    }

    @ViewBuilder
    private var downloadActions: some View {
        Button(model.L(workshop.libraryAsset == nil ? "workshop.library.import" : "workshop.library.select")) {
            workshop.importSelected()
        }
        .disabled(workshop.selectedAsset == nil)
        Button(model.L("workshop.library.apply")) { workshop.applySelected() }
            .buttonStyle(.borderedProminent)
            .disabled(workshop.libraryAsset?.supportStatus != .playable)
        Button(model.L("workshop.download.remove")) { workshop.pendingRemoval = workshop.selectedDownload }
            .disabled(workshop.selectedDownload == nil)
    }

    private var compatibilityNotice: some View {
        Text(model.L("workshop.compatibility.help"))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var operationStatus: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                if workshop.isBusy { ProgressView().controlSize(.small) }
                Text(model.L(workshop.statusKey))
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if workshop.canCancel {
                    Button(model.L("common.cancel")) { workshop.cancel() }
                }
                if workshop.retryItem != nil {
                    Button(model.L("workshop.download.retry")) { workshop.retryDownload() }
                        .disabled(mutationsDisabled || !workshop.isAuthenticated)
                }
            }
            if workshop.operation == "download" {
                if workshop.totalBytes > 0 {
                    ProgressView(value: Double(min(workshop.completedBytes, workshop.totalBytes)), total: Double(workshop.totalBytes))
                }
                Text("\(Self.byteCount(workshop.completedBytes)) / \(Self.byteCount(workshop.totalBytes))")
                    .font(.caption).monospacedDigit()
            }
            if workshop.canCancel {
                Text(model.L("workshop.cancel.help"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func isDownloaded(_ id: String) -> Bool {
        workshop.downloads.contains { $0.id == id }
    }

    private static func byteCount(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }
}
