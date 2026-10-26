import AppKit
import CoreGraphics
import MacRDPKit
import MacRDPHost
import Observation
import UniformTypeIdentifiers

/// The app's state: the server, its permissions and sign-in, and which windows are open.
@MainActor
@Observable
final class AppModel {
    enum ServerState: Equatable {
        case stopped
        case listening
        case connected(client: String, monitors: Int)
        case failed(String)
    }

    enum SettingsTab: Hashable {
        case signIn, permissions, connection, display
    }

    static let logFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/mac-rdp-server.log")

    private(set) var serverState = ServerState.stopped
    /// Why the last session was refused or closed, until the next one starts.
    private(set) var lastProblem: String?
    private(set) var permissions = Permissions.current()
    private(set) var credentials: Credentials?
    private(set) var addresses: [NetworkAddress] = []
    private(set) var settings = HostSettings.load()
    var settingsTab = SettingsTab.signIn

    var onboardingStep: Int {
        didSet { defaults.set(onboardingStep, forKey: "onboardingStep") }
    }
    private(set) var onboardingComplete: Bool {
        didSet { defaults.set(onboardingComplete, forKey: "onboardingComplete") }
    }
    /// The user wants the server running (started it, or finished setup), so it
    /// starts again after a relaunch.
    private var serverWanted: Bool {
        didSet { defaults.set(serverWanted, forKey: "serverWanted") }
    }
    /// Screen Recording was requested; macOS only applies it after a relaunch.
    private(set) var screenRecordingRequested: Bool {
        didSet { defaults.set(screenRecordingRequested, forKey: "screenRecordingRequested") }
    }

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private let windows = WindowPresenter()
    @ObservationIgnored private var host: RDPHost?
    @ObservationIgnored private var refreshTimer: Timer?
    let configDirectory = RDPHost.defaultConfigDirectory

    init() {
        onboardingStep = defaults.integer(forKey: "onboardingStep")
        onboardingComplete = defaults.bool(forKey: "onboardingComplete")
        screenRecordingRequested = defaults.bool(forKey: "screenRecordingRequested")
        serverWanted = defaults.bool(forKey: "serverWanted")
    }

    var menuBarSymbol: String {
        switch serverState {
        case .connected: "display.2"
        case .listening where permissions.allGranted: "display"
        default: "display.trianglebadge.exclamationmark"
        }
    }

    var statusText: String {
        switch serverState {
        case .stopped: "Server stopped"
        case .listening: "Waiting for Windows on port \(settings.port)"
        case let .connected(client, monitors): "Connected from \(client) · \(monitors) monitor\(monitors == 1 ? "" : "s")"
        case let .failed(message): message
        }
    }

    var isRunning: Bool { host != nil }

    // MARK: Launch

    func launch(showing window: String?) {
        refresh()
        reloadCredentials()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        if onboardingComplete || serverWanted { startServer() }
        switch window {
        case "settings": showSettings()
        case "onboarding": showOnboarding()
        default: if !onboardingComplete { showOnboarding() }
        }
    }

    /// Permissions change in System Settings and addresses change with the network.
    func refresh() {
        permissions = .current()
        addresses = NetworkAddress.current()
    }

    // MARK: Server

    func startServer() {
        guard host == nil else { return }
        guard credentials != nil else {
            serverState = .failed("Set a sign-in password first.")
            return
        }
        let host = RDPHost(options: settings.options)
        host.onEvent = { [weak self] event in self?.handle(event) }
        do {
            try host.start()
            self.host = host
            serverState = .listening
            serverWanted = true
        } catch {
            serverState = .failed("Could not start: \(error)")
        }
    }

    /// The user's Stop: the server stays off across relaunches until started again.
    func stopServerByUser() {
        serverWanted = false
        stopServer()
    }

    func stopServer() {
        host?.stop()
        host = nil
        serverState = .stopped
    }

    func disconnectClient() {
        host?.disconnectClient()
    }

    /// Saves new settings; a running server restarts to use them.
    func apply(_ new: HostSettings) {
        settings = new
        new.save(to: defaults)
        if host != nil {
            stopServer()
            startServer()
        }
    }

    private func handle(_ event: HostEvent) {
        switch event {
        case let .connected(client, monitors):
            serverState = .connected(client: client, monitors: monitors)
            lastProblem = nil
        case .disconnected:
            if host != nil { serverState = .listening }
        case let .problem(message):
            lastProblem = message
        }
    }

    // MARK: Sign-in

    func reloadCredentials() {
        credentials = CredentialStore.load(directory: configDirectory)
    }

    func saveCredentials(user: String, password: String) throws {
        try CredentialStore.save(user: user, password: password, directory: configDirectory)
        reloadCredentials()
        if onboardingComplete, host == nil { startServer() }
    }

    // MARK: Permissions

    func requestScreenRecording() {
        // The request lists the app in System Settings (and prompts the first time).
        _ = CGRequestScreenCaptureAccess()
        screenRecordingRequested = true
        NSWorkspace.shared.open(PrivacyPane.screenRecording.url)
    }

    func requestAccessibility() {
        _ = InputInjector.isTrusted(prompt: true)
        NSWorkspace.shared.open(PrivacyPane.accessibility.url)
    }

    /// Starts a fresh copy of the app (so new permissions apply) and quits this one.
    func relaunch() {
        stopServer()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = onboardingComplete ? ["--show", "settings"] : []
        if onboardingComplete { settingsTab = .permissions }
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    // MARK: Windows

    func showOnboarding() {
        windows.show("onboarding", title: "Set Up mac-rdp-server") { OnboardingView(model: self) }
    }

    func showSettings(_ tab: SettingsTab? = nil) {
        if let tab { settingsTab = tab }
        windows.show("settings", title: "mac-rdp-server Settings") { SettingsView(model: self) }
    }

    func finishOnboarding() {
        onboardingComplete = true
        onboardingStep = 0
        windows.close("onboarding")
        startServer()
    }

    func openLog() {
        NSWorkspace.shared.open(Self.logFile)
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Writes a Remote Desktop file the Windows PC can double-click.
    func saveRemoteDesktopFile(address: String) {
        guard let user = credentials?.user else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "mac-rdp-server.rdp"
        panel.allowedContentTypes = [UTType(filenameExtension: "rdp") ?? .data]
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try RemoteDesktopFile.contents(address: address, port: settings.port, user: user)
                .write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}
