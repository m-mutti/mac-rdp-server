import AppKit
import Foundation
import MacRDPKit

/// The thread-safe half of clipboard sharing: answers Windows' paste requests
/// and fetches Windows' clipboard, both on FreeRDP's threads.
final class ClipboardChannel: @unchecked Sendable {
    typealias Format = (id: UInt32, name: String?, kind: WindowsClipboard.Kind)

    private let link: SessionLink
    private let lock = NSLock()
    /// What each format ID offered to Windows stands for.
    private var offered: [UInt32: WindowsClipboard.Kind] = [:]
    private var waiter: DispatchSemaphore?
    private var answer: Data?
    /// Answers to fetches that timed out; they must not satisfy a later fetch.
    private var staleAnswers = 0
    private var closed = false
    private let reads = DispatchQueue(label: "mac-rdp-server.clipboard", qos: .userInitiated)
    private let fetches = DispatchQueue(label: "mac-rdp-server.clipboard-fetch", qos: .userInitiated)
    private var fetchGeneration = UUID()

    struct RemoteFormat: Sendable {
        let type: String
        let id: UInt32
        let kind: WindowsClipboard.Kind
    }

    /// Fetch in wire order on a worker. Publish text first, then enrich it with
    /// other formats; AppKit never waits for network data in a paste callback.
    func prefetch(_ formats: [RemoteFormat],
                  receive: @escaping @Sendable (String, Data) -> Void) {
        let generation = UUID()
        lock.withLock { fetchGeneration = generation }
        fetches.async { [self] in
            for format in formats {
                guard lock.withLock({ !closed && fetchGeneration == generation }) else { return }
                guard let raw = fetch(format.id, timeout: 3) else { return }
                guard lock.withLock({ !closed && fetchGeneration == generation }) else { return }
                let converted: Data?
                switch format.kind {
                case .text:
                    converted = WindowsClipboard.text(fromUnicode: raw)?.data(using: .utf8)
                case .html:
                    converted = WindowsClipboard.html(fromHTMLFormat: raw)?.data(using: .utf8)
                case .bitmap: converted = WindowsClipboard.png(fromDIB: raw)
                case .rtf, .png: converted = raw
                }
                if let converted { receive(format.type, converted) }
            }
        }
    }

    init(link: SessionLink) {
        self.link = link
    }

    /// Tells Windows what the Mac clipboard holds.
    func offer(_ formats: [Format]) {
        lock.withLock { offered = Dictionary(formats.map { ($0.id, $0.kind) }, uniquingKeysWith: { a, _ in a }) }
        link.clipboardOffer(formats.map { ($0.id, $0.name) })
    }

    /// Windows is pasting. The Mac clipboard is read off the main thread:
    /// macOS may first ask whether to allow it, and the user answers that
    /// through Remote Desktop, which needs the main thread free.
    func handleRequest(_ id: UInt32) {
        let kind = lock.withLock { offered[id] }
        let link = self.link
        reads.async {
            link.clipboardSend(kind.flatMap(Self.readMacClipboard))
        }
    }

    /// Waits for Windows' clipboard in format `id`; nil if it fails or takes longer than `timeout`.
    private func fetch(_ id: UInt32, timeout: TimeInterval) -> Data? {
        let semaphore = DispatchSemaphore(value: 0)
        let ready = lock.withLock {
            guard !closed else { return false }
            waiter = semaphore
            answer = nil
            return true
        }
        guard ready else { return nil }
        guard link.clipboardFetch(id) else {
            lock.withLock { waiter = nil }
            return nil
        }
        let answered = semaphore.wait(timeout: .now() + timeout) == .success
        return lock.withLock {
            defer {
                waiter = nil
                answer = nil
            }
            if !answered { staleAnswers += 1 }
            return answered ? answer : nil
        }
    }

    /// Windows' answer to a fetch (FreeRDP's clipboard thread).
    func deliver(_ data: Data?) {
        lock.withLock {
            if staleAnswers > 0 {
                staleAnswers -= 1
                return
            }
            answer = data
            waiter?.signal()
        }
    }

    func close() {
        lock.withLock {
            closed = true
            waiter?.signal()
        }
    }

    private static func readMacClipboard(_ kind: WindowsClipboard.Kind) -> Data? {
        let pasteboard = NSPasteboard.general
        let image = { pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) }
        switch kind {
        case .text: return pasteboard.string(forType: .string).map(WindowsClipboard.unicode(from:))
        case .html: return pasteboard.string(forType: .html).map(WindowsClipboard.htmlFormat(from:))
        case .rtf: return pasteboard.data(forType: .rtf)
        case .png: return pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff).flatMap(WindowsClipboard.png(fromImage:))
        case .bitmap: return image().flatMap(WindowsClipboard.dib(fromImage:))
        }
    }
}

/// Keeps the Mac and Windows clipboards in step while a session is active:
/// text, formatted text and images, both ways. Windows data is prefetched
/// so an AppKit paste callback never waits for a network response.
@MainActor
final class ClipboardSync: NSObject {
    /// IDs for the registered formats we offer (Windows wants 0xC000 and up).
    private enum Registered {
        static let html: UInt32 = 0xC001
        static let rtf: UInt32 = 0xC002
        static let png: UInt32 = 0xC003
    }

    nonisolated let channel: ClipboardChannel
    private var timer: DispatchSourceTimer?
    private var seenChange = NSPasteboard.general.changeCount
    /// The change count of our own last write, which must not be offered back.
    private var ownChange: Int?
    private var incomingGeneration = UUID()
    private var incomingData: [NSPasteboard.PasteboardType: Data] = [:]
    private var stopped = false

    init(channel: ClipboardChannel) {
        self.channel = channel
    }

    /// The client shares its clipboard: offer what the Mac holds and keep watching.
    func start() {
        guard timer == nil else { return }
        stopped = false
        log("sharing the clipboard")
        offerMacClipboard()
        // macOS has no clipboard change notification.
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(300), repeating: .milliseconds(300))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        stopped = true
        incomingGeneration = UUID()
        timer?.cancel()
        timer = nil
        channel.close()
    }

    /// Publish each cached format only while this remote copy is current and
    /// the Mac clipboard hasn't been changed locally in the meantime.
    func windowsOffered(_ formats: [(id: UInt32, name: String?)]) {
        incomingGeneration = UUID()
        let generation = incomingGeneration
        incomingData = [:]
        func named(_ name: String) -> UInt32? { formats.first { $0.name == name }?.id }
        func standard(_ id: UInt32) -> UInt32? { formats.contains { $0.id == id } ? id : nil }
        var requested: [ClipboardChannel.RemoteFormat] = []
        func add(_ type: NSPasteboard.PasteboardType, _ id: UInt32?, _ kind: WindowsClipboard.Kind) {
            if let id { requested.append(.init(type: type.rawValue, id: id, kind: kind)) }
        }
        add(.string, standard(WindowsClipboard.unicodeText), .text)
        add(.html, named(WindowsClipboard.htmlName), .html)
        add(.rtf, named(WindowsClipboard.rtfName), .rtf)
        if let png = named(WindowsClipboard.pngName) {
            add(.png, png, .png)
        } else {
            add(.png, standard(WindowsClipboard.dibV5) ?? standard(WindowsClipboard.dib), .bitmap)
        }
        guard !requested.isEmpty else {
            channel.prefetch([]) { _, _ in }
            return
        }
        // Invalidate the previous copy immediately. An early paste must not
        // accidentally insert old contents while the new data is in transit.
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        ownChange = pasteboard.changeCount
        seenChange = pasteboard.changeCount
        // The expected change count lives on the main actor with the cache.
        let revision = ClipboardRevision(pasteboard.changeCount)
        channel.prefetch(requested) { [weak self] type, data in
            DispatchQueue.main.async {
                guard let self, !self.stopped, self.incomingGeneration == generation,
                      NSPasteboard.general.changeCount == revision.value else { return }
                self.incomingData[NSPasteboard.PasteboardType(type)] = data
                let item = NSPasteboardItem()
                for (type, data) in self.incomingData { item.setData(data, forType: type) }
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.writeObjects([item])
                revision.value = pasteboard.changeCount
                self.ownChange = pasteboard.changeCount
                self.seenChange = pasteboard.changeCount
            }
        }
    }

    @MainActor private final class ClipboardRevision {
        var value: Int
        init(_ value: Int) { self.value = value }
    }

    private func poll() {
        let change = NSPasteboard.general.changeCount
        guard change != seenChange else { return }
        seenChange = change
        if change != ownChange { offerMacClipboard() }
    }

    /// Offers what's on the Mac clipboard by type only; contents are read when Windows pastes.
    private func offerMacClipboard() {
        let types = Set(NSPasteboard.general.types ?? [])
        var formats: [ClipboardChannel.Format] = []
        if types.contains(.string) { formats.append((WindowsClipboard.unicodeText, nil, .text)) }
        if types.contains(.html) { formats.append((Registered.html, WindowsClipboard.htmlName, .html)) }
        if types.contains(.rtf) { formats.append((Registered.rtf, WindowsClipboard.rtfName, .rtf)) }
        if !types.isDisjoint(with: [.png, .tiff]) {
            formats.append((Registered.png, WindowsClipboard.pngName, .png))
            formats.append((WindowsClipboard.dib, nil, .bitmap))
        }
        channel.offer(formats)
    }
}
