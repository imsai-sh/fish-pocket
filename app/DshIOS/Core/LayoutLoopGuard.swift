import Foundation
import os

/// Debug builds only: a layout loop said the moment it starts. A view whose size or place is
/// measured and written back to state, where it changes what was measured, can lay itself out
/// again and again without end, and the app hangs (the notices over a closing sheet did). The
/// places that measure and keep call `tick` with a name; one name heard far more often than any
/// layout or animation needs, within a second, is logged as a fault in the console, once in a
/// while, so a loop shows when it is brought in rather than on someone's phone. With the launch
/// argument `-dshLayoutLoopTrap YES` it also stops in the debugger there.
///
/// Release builds keep only an empty function.
enum LayoutLoopGuard {
    @inline(__always)
    static func tick(_ name: StaticString) {
        #if DEBUG
        Counter.shared.tick(name)
        #endif
    }

    #if DEBUG
    /// A second's worth of ticks per name. An animation or a scroll lays out at most once per
    /// frame (120 a second); a loop does thousands.
    private final class Counter: @unchecked Sendable {
        static let shared = Counter()
        private static let limit = 480
        private static let logger = Logger(subsystem: "com.wsw.dsh-ios", category: "layout-loop")
        private let lock = NSLock()
        private var windows: [String: (start: TimeInterval, count: Int, said: TimeInterval)] = [:]
        private let trap = UserDefaults.standard.bool(forKey: "dshLayoutLoopTrap")

        func tick(_ name: StaticString) {
            let key = "\(name)"
            let now = ProcessInfo.processInfo.systemUptime
            lock.lock()
            var window = windows[key] ?? (now, 0, 0)
            if now - window.start > 1 { window = (now, 0, window.said) }
            window.count += 1
            let loud = window.count > Self.limit && now - window.said > 10
            if loud { window.said = now }
            windows[key] = window
            lock.unlock()
            guard loud else { return }
            Self.logger.fault("Layout loop? \(key, privacy: .public) ran more than \(Self.limit) times within a second")
            if trap { raise(SIGTRAP) }
        }
    }
    #endif
}
