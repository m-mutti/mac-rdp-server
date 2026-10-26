import SwiftUI

/// First-run setup: what the app does, permissions, sign-in, and how to connect.
struct OnboardingView: View {
    @Bindable var model: AppModel

    private let steps = ["Welcome", "Permissions", "Sign-in", "Connect"]

    var body: some View {
        VStack(spacing: 0) {
            stepIndicator.padding(.vertical, 14)
            Divider()
            Group {
                switch model.onboardingStep {
                case 1: permissions
                case 2: signIn
                case 3: connect
                default: welcome
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            footer.padding(14)
        }
        .frame(width: 580, height: 500)
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "display.2").font(.system(size: 40)).foregroundStyle(.tint)
            Text("Use your Windows PC as your Mac's screen").font(.title2.bold())
            Text("Connect from Windows with the built-in Remote Desktop Connection. Every Windows monitor becomes a Mac display, and your Windows keyboard and mouse control the Mac.")
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 10) {
                bullet("lock.shield", "Allow two macOS permissions")
                bullet("key.fill", "Choose the password Windows signs in with")
                bullet("pc", "Connect from your Windows PC")
            }
            .padding(.top, 4)
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Allow access").font(.title2.bold())
            Text("macOS asks before any app can show your screen to another computer or accept keyboard and mouse input. Switch on **mac-rdp-connect** in each list.")
                .fixedSize(horizontal: false, vertical: true)
            PermissionsChecklist(model: model)
        }
    }

    private var signIn: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose how Windows signs in").font(.title2.bold())
            Text("This is separate from your Mac login password. You can view or change it later in Settings.")
                .fixedSize(horizontal: false, vertical: true)
            CredentialsForm(model: model)
        }
    }

    private var connect: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect from Windows").font(.title2.bold())
            numbered(1, "Open **Remote Desktop Connection** on the Windows PC.")
            numbered(2, "Enter one of these addresses:")
            AddressList(model: model).padding(.leading, 28)
            numbered(3, "Click **Show Options › Display** and tick **Use all my monitors**.")
            numbered(4, "Connect, sign in with the user name and password you just chose, and accept the certificate prompt.")
            HStack {
                Text("Or copy a ready-made file to the PC:").foregroundStyle(.secondary)
                Spacer()
            }
            RemoteDesktopFileButton(model: model)
        }
    }

    // MARK: Chrome

    private var stepIndicator: some View {
        HStack(spacing: 8) {
            ForEach(steps.indices, id: \.self) { i in
                HStack(spacing: 6) {
                    Text("\(i + 1)")
                        .font(.caption.bold())
                        .frame(width: 20, height: 20)
                        .background(i <= model.onboardingStep ? Color.accentColor : Color.secondary.opacity(0.3), in: Circle())
                        .foregroundStyle(.white)
                    Text(steps[i])
                        .font(.callout)
                        .foregroundStyle(i == model.onboardingStep ? .primary : .secondary)
                }
                if i < steps.count - 1 {
                    Rectangle().fill(.quaternary).frame(width: 24, height: 1)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            if model.onboardingStep > 0 {
                Button("Back") { model.onboardingStep -= 1 }
            }
            Spacer()
            switch model.onboardingStep {
            case 0:
                Button("Get Started") { model.onboardingStep = 1 }.keyboardShortcut(.defaultAction)
            case 1:
                Button(model.permissions.allGranted ? "Continue" : "Skip for Now") { model.onboardingStep = 2 }
                    .keyboardShortcut(model.permissions.allGranted ? .defaultAction : nil)
            case 2:
                Button("Continue") { model.onboardingStep = 3 }
                    .disabled(model.credentials == nil)
                    .help(model.credentials == nil ? "Save a password first" : "")
            default:
                Button("Finish", action: model.finishOnboarding).keyboardShortcut(.defaultAction)
            }
        }
    }

    private func bullet(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: symbol).foregroundStyle(.tint).frame(width: 22)
        }
    }

    private func numbered(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n).").bold().frame(width: 20, alignment: .trailing)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}
