import MacRDPKit
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView(selection: $model.settingsTab) {
            pane { CredentialsForm(model: model) }
                .tabItem { Label("Sign-in", systemImage: "key.fill") }
                .tag(AppModel.SettingsTab.signIn)
            pane { PermissionsChecklist(model: model) }
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
                .tag(AppModel.SettingsTab.permissions)
            pane { ConnectionSettings(model: model) }
                .tabItem { Label("Connection", systemImage: "network") }
                .tag(AppModel.SettingsTab.connection)
            pane { DisplaySettings(model: model) }
                .tabItem { Label("Display & Keyboard", systemImage: "display.2") }
                .tag(AppModel.SettingsTab.display)
        }
        .frame(width: 560, height: 400)
    }

    private func pane<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct ConnectionSettings: View {
    let model: AppModel
    @State private var port: UInt16 = 3389

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(model.statusText).foregroundStyle(.secondary)
                Spacer()
                if model.isRunning {
                    Button("Stop Server", action: model.stopServerByUser)
                } else {
                    Button("Start Server", action: model.startServer)
                }
            }
            LabeledContent("Port") {
                HStack {
                    TextField("Port", value: $port, format: .number.grouping(.never))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                    Button("Apply") {
                        var settings = model.settings
                        settings.port = port
                        model.apply(settings)
                    }
                    .disabled(port == model.settings.port || port == 0)
                    Spacer()
                }
            }
            Divider()
            Text("Windows connects to").font(.headline)
            AddressList(model: model)
            RemoteDesktopFileButton(model: model)
        }
        .onAppear { port = model.settings.port }
    }
}

private struct DisplaySettings: View {
    let model: AppModel
    @State private var draft = HostSettings()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Form {
                Picker("Keyboard", selection: $draft.keys) {
                    Text("Windows key acts as ⌘ (like a PC keyboard on a Mac)").tag(ModifierStyle.mac)
                    Text("Ctrl acts as ⌘ (keep Windows shortcuts)").tag(ModifierStyle.windowsShortcuts)
                }
                Picker("Scaling", selection: $draft.scaling) {
                    Text("Match Windows scaling (sharp, Retina-style)").tag(ScalingPolicy.matchClient)
                    Text("One Mac point per Windows pixel").tag(ScalingPolicy.native)
                }
                Picker("Mac's own screen", selection: $draft.physical) {
                    Text("Mirror the main Windows monitor").tag(PhysicalDisplayPolicy.mirror)
                    Text("Keep as extra space").tag(PhysicalDisplayPolicy.extend)
                }
                Toggle("Compatibility video (try if Windows connects but stays black)", isOn: $draft.compatibilityVideo)
            }
            HStack {
                if case .connected = model.serverState, draft != model.settings {
                    Text("Applying restarts the server and disconnects Windows.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Apply") { model.apply(draft) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft == model.settings)
            }
        }
        .onAppear { draft = model.settings }
    }
}
