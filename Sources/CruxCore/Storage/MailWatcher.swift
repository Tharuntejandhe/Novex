import Foundation

/// Watches Apple Mail's local store and fires `onChange` (debounced) the moment
/// it changes — so new mail triggers a refresh + notification within ~2–3s, even
/// when Crux's panel is closed. Event-driven via FSEvents (NOT polling), so it
/// costs nothing while the inbox is idle — gentle on battery.
final class MailWatcher {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.tarun.crux.mailwatch", qos: .utility)
    private var debounce: DispatchWorkItem?
    private let onChange: () -> Void
    private let path: String

    /// `onChange` is invoked on a background queue — hop to the main actor inside it.
    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        self.path = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Mail")
    }

    func start() {
        guard stream == nil, FileManager.default.fileExists(atPath: path) else { return }
        var ctx = FSEventStreamContext(version: 0,
                                       info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<MailWatcher>.fromOpaque(info).takeUnretainedValue().scheduleFire()
        }
        let flags = UInt32(kFSEventStreamCreateFlagNoDefer
                           | kFSEventStreamCreateFlagFileEvents
                           | kFSEventStreamCreateFlagIgnoreSelf)
        guard let s = FSEventStreamCreate(nil, callback, &ctx,
                                          [path] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                          2.0, flags) else { return }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
    }

    /// Coalesce a burst of file writes (Mail touches many files per sync) into one fire.
    private func scheduleFire() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        debounce = work
        queue.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s)
        stream = nil
    }

    deinit { stop() }
}
