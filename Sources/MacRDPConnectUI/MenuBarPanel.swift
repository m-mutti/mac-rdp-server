import AppKit
import SwiftUI

/// What opens from the menu bar icon: status, how to connect, and controls.
struct MenuBarPanel: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("mac-rdp-connect").font(.headline)
                Spacer()
                Circle().fill(statusColor).frame(width: 8, height: 8)
            }
            Text(model.statusText)
                .font(.callout)
                .foregroundStyle(isFailed ? .red : .secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let problem = model.lastProblem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !model.permissions.allGranted {
                attention("Permissions needed for Windows to see and control the Mac.", action: "Fix…") {
                    model.showSettings(.permissions)
                }
            }
            if model.credentials == nil {
                attention("No sign-in password yet.", action: "Set…") { model.showSettings(.signIn) }
            }

            Divider()
            Text("Connect from Windows").font(.subheadline.weight(.semibold))
            AddressList(model: model)

            Divider()
            HStack {
                if model.isRunning {
                    Button("Stop Server", action: model.stopServer)
                } else {
                    Button("Start Server", action: model.startServer)
                }
                if case .connected = model.serverState {
                    Button("Disconnect", action: model.disconnectClient)
                }
            }

            Divider()
            VStack(alignment: .leading, spacing: 6) {
                if !model.onboardingComplete {
                    menuButton("Set Up…", action: model.showOnboarding)
                }
                menuButton("Settings…") { model.showSettings() }
                menuButton("Open Log", action: model.openLog)
                menuButton("Quit mac-rdp-connect") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    private var isFailed: Bool {
        if case .failed = model.serverState { true } else { false }
    }

    private var statusColor: Color {
        switch model.serverState {
        case .connected: .green
        case .listening: model.permissions.allGranted ? .blue : .orange
        case .stopped: .gray
        case .failed: .red
        }
    }

    private func attention(_ text: String, action: String, perform: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(action, action: perform)
        }
    }

    private func menuButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }
}
