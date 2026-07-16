import Foundation

/// KVO wrapper for one `UserDefaults` key. Unlike
/// `UserDefaults.didChangeNotification` (same-process writes only), KVO
/// deliveries also cover writes from other processes (`defaults write …`)
/// via cfprefsd — which is what makes runtime re-configuration and test
/// automation possible.
final class DefaultsKeyObserver: NSObject {
    private let key: String
    private let onChange: @Sendable () -> Void

    init(key: String, onChange: @escaping @Sendable () -> Void) {
        self.key = key
        self.onChange = onChange
        super.init()
        UserDefaults.standard.addObserver(self, forKeyPath: key, options: [.new], context: nil)
    }

    deinit {
        UserDefaults.standard.removeObserver(self, forKeyPath: key)
    }

    override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        guard keyPath == key else { return }
        DebugLog.info("DefaultsKeyObserver[\(key)] fired (thread=\(Thread.isMainThread ? "main" : "bg"))")
        onChange()
    }
}
