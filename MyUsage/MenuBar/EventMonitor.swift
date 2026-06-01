import AppKit

/// Thin wrapper around an `NSEvent` monitor that removes itself on `stop()`
/// or deallocation. Handlers are delivered on the main thread by AppKit.
class EventMonitor {
    private var monitor: Any?
    let mask: NSEvent.EventTypeMask

    init(mask: NSEvent.EventTypeMask) {
        self.mask = mask
    }

    deinit {
        stop()
    }

    func start() {}

    func stop() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
    }

    fileprivate func store(_ monitor: Any?) {
        self.monitor = monitor
    }
}

/// Watches events delivered to this app. Return the event to pass it along,
/// or `nil` to consume it (e.g. swallow a status-item click we handle ourselves).
final class LocalEventMonitor: EventMonitor {
    private let handler: (NSEvent) -> NSEvent?

    init(mask: NSEvent.EventTypeMask, handler: @escaping (NSEvent) -> NSEvent?) {
        self.handler = handler
        super.init(mask: mask)
    }

    override func start() {
        store(NSEvent.addLocalMonitorForEvents(matching: mask, handler: handler))
    }
}

/// Watches events delivered to *other* apps — used to detect clicks outside
/// our panel so we can dismiss it.
final class GlobalEventMonitor: EventMonitor {
    private let handler: (NSEvent) -> Void

    init(mask: NSEvent.EventTypeMask, handler: @escaping (NSEvent) -> Void) {
        self.handler = handler
        super.init(mask: mask)
    }

    override func start() {
        store(NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler))
    }
}
