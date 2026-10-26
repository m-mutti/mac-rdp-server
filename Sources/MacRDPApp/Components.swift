import AppKit
import MacRDPHost
import SwiftUI

/// Screen Recording and Accessibility with live status and a way to fix each.
struct PermissionsChecklist: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PermissionRow(title: "Screen Recording",
                          detail: "Lets Windows see your Mac's screen.",
                          granted: model.permissions.screenRecording,
                          action: model.requestScreenRecording)
            PermissionRow(title: "Accessibility",
                          detail: "Lets your Windows keyboard and mouse control the Mac.",
                          granted: model.permissions.accessibility,
                          action: model.requestAccessibility)

            if model.screenRecordingRequested && !model.permissions.screenRecording {
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: "arrow.clockwise")
                    Text("Already switched on Screen Recording? macOS applies it after mac-rdp-server restarts.")
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Restart", action: model.relaunch)
                }
                .font(.callout)
                .padding(10)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.title2)
                .foregroundStyle(granted ? .green : .red)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Text("Allowed").foregroundStyle(.secondary)
            } else {
                Button("Open Settings…", action: action)
            }
        }
    }
}

/// Shows and edits the user name and password Windows signs in with.
struct CredentialsForm: View {
    let model: AppModel
    /// Lets an unchanged, already saved sign-in count as done (onboarding).
    var onSaved: () -> Void = {}

    @State private var user = ""
    @State private var password = ""
    @State private var reveal = false
    @State private var status: (text: String, isError: Bool)?

    private var saved: Credentials? { model.credentials }
    private var isChanged: Bool { user != saved?.user || password != (saved?.password ?? "") }
    private var canSave: Bool {
        !user.isEmpty && password.count >= CredentialStore.minimumPasswordLength && isChanged
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("User name").gridColumnAlignment(.trailing)
                    TextField("User name", text: $user, prompt: Text(NSUserName()))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Password")
                    HStack(spacing: 6) {
                    Group {
                        if reveal {
                            TextField("Password", text: $password)
                        } else {
                            SecureField("Password", text: $password)
                        }
                    }
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    iconButton(reveal ? "eye.slash" : "eye", help: reveal ? "Hide password" : "Show password") {
                        reveal.toggle()
                    }
                    iconButton("dice", help: "Generate a password") {
                        password = CredentialStore.generatePassword()
                        reveal = true
                    }
                    iconButton("doc.on.doc", help: "Copy password") { model.copy(password) }
                        .disabled(password.isEmpty)
                    }
                }
            }

            Group {
                if saved != nil && saved?.password == nil && password.isEmpty {
                    Text("A password is set, but it was saved from the command line and can't be shown. Enter a new one to change it.")
                } else {
                    Text("Windows asks for these when you connect. Use at least \(CredentialStore.minimumPasswordLength) characters.")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                if let status {
                    Label(status.text, systemImage: status.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(status.isError ? .red : .green)
                        .font(.callout)
                }
                Spacer()
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .onAppear {
            user = saved?.user ?? NSUserName()
            password = saved?.password ?? ""
        }
        .onChange(of: user) { status = nil }
        .onChange(of: password) { status = nil }
    }

    private func save() {
        do {
            try model.saveCredentials(user: user, password: password)
            status = ("Saved. Windows uses these from its next sign-in.", false)
            onSaved()
        } catch {
            status = (error.localizedDescription, true)
        }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 16) }
            .buttonStyle(.borderless)
            .help(help)
            .accessibilityLabel(help)
    }
}

/// The addresses Windows can connect to, each copyable.
struct AddressList: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.addresses.isEmpty {
                Text("No network connection").foregroundStyle(.secondary)
            }
            ForEach(model.addresses, id: \.self) { address in
                row(value: portSuffixed(address.address), label: address.label)
            }
            if let user = model.credentials?.user {
                row(value: user, label: "User name")
            }
        }
    }

    private func portSuffixed(_ address: String) -> String {
        model.settings.port == 3389 ? address : "\(address):\(model.settings.port)"
    }

    private func row(value: String, label: String) -> some View {
        HStack {
            Text(value).font(.body.monospaced()).textSelection(.enabled)
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button { model.copy(value) } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless)
                .help("Copy")
                .accessibilityLabel("Copy \(label)")
        }
    }
}

/// Saves a .rdp file for whichever address the user picks.
struct RemoteDesktopFileButton: View {
    let model: AppModel
    @State private var address = ""

    var body: some View {
        HStack {
            Picker("Address in file", selection: $address) {
                ForEach(model.addresses, id: \.address) { a in
                    Text("\(a.address) (\(a.label))").tag(a.address)
                }
            }
            .fixedSize()
            Button("Save Remote Desktop File…") { model.saveRemoteDesktopFile(address: address) }
                .disabled(address.isEmpty || model.credentials == nil)
        }
        .onAppear { if address.isEmpty { address = model.addresses.first?.address ?? "" } }
    }
}
