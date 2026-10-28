import Foundation
import Testing
import MacRDPKit
@testable import MacRDPApp

struct HostSettingsTests {
    @Test func qualityPersistsAndRetunesWithoutRestartingTheServer() throws {
        let domain = "mac-rdp-server-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let previous = HostSettings.load(from: defaults)
        #expect(previous.videoQuality == .balanced)
        var sharper = previous
        sharper.videoQuality = .sharper
        #expect(!sharper.requiresServerRestart(comparedTo: previous))
        sharper.save(to: defaults)
        #expect(HostSettings.load(from: defaults) == sharper)
        #expect(sharper.options.videoQuality == .sharper)
        sharper.port += 1
        #expect(sharper.requiresServerRestart(comparedTo: previous))
        defaults.set("unknown-future-preset", forKey: "videoQuality")
        #expect(HostSettings.load(from: defaults).videoQuality == .balanced)
    }
}
