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
    func fetch(_ id: UInt32, timeout: TimeInterval) -> Data? {
        let semaphore = DispatchSemaphore(value: 0)
        let ready = lock.withLock {
            guard !closed else { return false }
            waiter = semaphore
            answer = nil
            return true
        }
        guard ready, link.clipboardFetch(id) else { return nil }
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
/// text, formatted text and images, both ways. Data only crosses the network
/// when someone actually pastes.
@MainActor
final class ClipboardSync: NSObject, NSPasteboardItemDataProvider {
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
    /// Windows' format for each type promised on the Mac clipboard.
    private var promised: [NSPasteboard.PasteboardType: (id: UInt32, kind: WindowsClipboard.Kind)] = [:]

    init(channel: ClipboardChannel) {
        self.channel = channel
    }

    /// The client shares its clipboard: offer what the Mac holds and keep watching.
    func start() {
        guard timer == nil else { return }
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
        timer?.cancel()
        timer = nil
        channel.close()
    }

    /// Windows copied something: promise it on the Mac clipboard, fetched on paste.
    func windowsOffered(_ formats: [(id: UInt32, name: String?)]) {
        func named(_ name: String) -> UInt32? { formats.first { $0.name == name }?.id }
        func standard(_ id: UInt32) -> UInt32? { formats.contains { $0.id == id } ? id : nil }

        var promised: [NSPasteboard.PasteboardType: (id: UInt32, kind: WindowsClipboard.Kind)] = [:]
        if let id = standard(WindowsClipboard.unicodeText) { promised[.string] = (id, .text) }
        if let id = named(WindowsClipboard.htmlName) { promised[.html] = (id, .html) }
        if let id = named(WindowsClipboard.rtfName) { promised[.rtf] = (id, .rtf) }
        if let id = named(WindowsClipboard.pngName) {
            promised[.png] = (id, .png)
        } else if let id = standard(WindowsClipboard.dibV5) ?? standard(WindowsClipboard.dib) {
            promised[.png] = (id, .bitmap)
        }
        guard !promised.isEmpty else { return } // e.g. only files, which aren't shared yet

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setDataProvider(self, forTypes: Array(promised.keys))
        pasteboard.writeObjects([item])
        self.promised = promised
        ownChange = pasteboard.changeCount
        seenChange = pasteboard.changeCount
    }

    /// A Mac app pastes what Windows copied. AppKit calls this on the main
    /// thread and needs the data before it returns, so it waits for Windows.
    nonisolated func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem,
                                provideDataForType type: NSPasteboard.PasteboardType) {
        let promise = MainActor.assumeIsolated { promised[type] }
        guard let (id, kind) = promise, let raw = channel.fetch(id, timeout: 10) else { return }
        switch kind {
        case .text: WindowsClipboard.text(fromUnicode: raw).map { _ = item.setString($0, forType: type) }
        case .html: WindowsClipboard.html(fromHTMLFormat: raw).map { _ = item.setString($0, forType: type) }
        case .rtf, .png: item.setData(raw, forType: type)
        case .bitmap: WindowsClipboard.png(fromDIB: raw).map { _ = item.setData($0, forType: type) }
        }
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
