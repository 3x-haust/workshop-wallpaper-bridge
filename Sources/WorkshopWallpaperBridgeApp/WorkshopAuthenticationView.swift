import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

struct WorkshopAuthenticationView: View {
    @ObservedObject var model: AppViewModel
    @ObservedObject var workshop: WorkshopViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var password = ""
    @State private var guardCode = ""
    @State private var passwordLogin = false
    @State private var confirmsDeletion = false

    private var busy: Bool { workshop.isBusy || model.isWorking }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Label(model.L("workshop.browser.account"), systemImage: "person.crop.circle")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .accessibilityLabel(model.L("common.close"))
                    .keyboardShortcut(.cancelAction)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(workshop.account ?? model.L("workshop.account.disconnected"))
                        .font(.headline)
                    HStack(alignment: .top, spacing: 8) {
                        Text(model.L(workshop.hasSavedSession ? "workshop.credentials.saved" : "workshop.credentials.automatic"))
                            .font(.callout).foregroundStyle(BrowserPalette.secondary)
                        HelpPopoverButton(title: model.L("workshop.credentials.title"), message: model.L("workshop.credentials.help"))
                    }
                    if workshop.isAuthenticated {
                        Button(model.L("workshop.logout")) { workshop.logout() }
                            .disabled(busy).help(model.L("workshop.logout.help"))
                    } else {
                        if workshop.hasSavedSession {
                            Button(model.L("workshop.resume")) { workshop.resume() }
                                .buttonStyle(.borderedProminent).disabled(busy)
                        }
                        Picker(model.L("workshop.login.method"), selection: $passwordLogin) {
                            Text(model.L("workshop.login.qr.method")).tag(false)
                            Text(model.L("workshop.login.password.method")).tag(true)
                        }
                        .pickerStyle(.segmented).disabled(busy)
                        if passwordLogin {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(model.L("workshop.login.username")).font(.caption)
                                TextField(model.L("workshop.login.username"), text: $username)
                                    .textContentType(.username)
                                Text(model.L("workshop.login.password")).font(.caption)
                                SecureField(model.L("workshop.login.password"), text: $password)
                                    .textContentType(.password).onSubmit(login)
                                Button(model.L("workshop.login.submit"), action: login)
                                    .buttonStyle(.borderedProminent)
                                    .disabled(username.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty)
                            }
                            .textFieldStyle(.roundedBorder).disabled(busy)
                        } else if let value = workshop.qrURL {
                            HStack(spacing: 18) {
                                if let image = Self.qrImage(value) {
                                    Image(nsImage: image).interpolation(.none).resizable().scaledToFit()
                                        .frame(width: 160, height: 160).padding(12).background(.white)
                                        .accessibilityLabel(model.L("workshop.auth.qr.image"))
                                } else {
                                    Text(model.L("workshop.auth.qr.unavailable"))
                                }
                                Text(model.L("workshop.auth.scan")).font(.callout)
                            }
                        } else {
                            Button(model.L("workshop.login.qr")) { workshop.loginQR() }
                                .buttonStyle(.borderedProminent).disabled(busy)
                        }
                        if let prompt = workshop.authPrompt {
                            if prompt == "emailCode" || prompt == "twoFactor" {
                                Text(model.L(prompt == "emailCode" ? "workshop.auth.emailCode" : "workshop.auth.twoFactor"))
                                    .font(.callout)
                                HStack {
                                    SecureField(model.L("workshop.auth.code"), text: $guardCode)
                                        .textFieldStyle(.roundedBorder).onSubmit(submitGuard)
                                    Button(model.L("workshop.auth.submit"), action: submitGuard)
                                        .disabled(guardCode.isEmpty || !workshop.canCancel)
                                }
                            } else if prompt == "mobileApproval" {
                                Text(model.L("workshop.auth.mobileApproval")).font(.callout)
                            }
                        }
                    }
                    Divider()
                    HStack(alignment: .top) {
                        if workshop.isBusy { ProgressView().controlSize(.small) }
                        Text(model.L(workshop.statusKey)).font(.caption).foregroundStyle(BrowserPalette.secondary)
                        Spacer()
                        if workshop.canCancel {
                            Button(model.L("common.cancel")) { workshop.cancel() }
                                .help(model.L("workshop.cancel.help"))
                        }
                    }
                    if workshop.hasStoredAuthentication {
                        Button(model.L("workshop.credentials.delete"), role: .destructive) { confirmsDeletion = true }
                            .disabled(busy)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(24).frame(width: 500).frame(maxHeight: 620)
        .background(BrowserPalette.sidebar).foregroundStyle(BrowserPalette.text)
        .preferredColorScheme(.dark).tint(BrowserPalette.accent)
        .confirmationDialog(model.L("workshop.credentials.delete.title"), isPresented: $confirmsDeletion, titleVisibility: .visible) {
            Button(model.L("workshop.credentials.delete"), role: .destructive) { workshop.deleteSavedAuthentication() }
                .disabled(busy)
            Button(model.L("common.cancel"), role: .cancel) {}
        } message: {
            Text(model.L("workshop.credentials.delete.message"))
        }
        .onChange(of: workshop.authPrompt) { _, _ in guardCode = "" }
        .onChange(of: workshop.operation) { _, _ in password = ""; guardCode = "" }
        .onChange(of: workshop.isAuthenticated) { _, authenticated in
            if authenticated { dismiss() }
        }
        .onDisappear {
            password = ""
            guardCode = ""
            if workshop.operation == "login" { workshop.cancel() }
        }
    }

    private func login() {
        guard !busy else { return }
        workshop.login(username: username, password: password)
        password = ""
    }

    private func submitGuard() {
        guard workshop.canCancel, !guardCode.isEmpty else { return }
        workshop.submitGuard(guardCode)
        guardCode = ""
    }

    private static func qrImage(_ value: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}
