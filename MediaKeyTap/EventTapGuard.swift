//
//  EventTapGuard.swift
//
//  Self-contained (AppKit and CoreGraphics only), so the same file can be
//  copied into any app that runs an active CGEvent tap. `nonisolated` keeps it
//  off the main actor in targets that make that the default isolation, and
//  `Dispatch.DispatchWorkItem` is spelled out for apps that define their own.
//

import AppKit
import CoreGraphics
import Dispatch

/// Keeps an active CGEvent tap from freezing the keyboard and mouse when the
/// app's Accessibility permission is revoked.
///
/// A `.defaultTap` tap that outlives its app's Accessibility stays in the event
/// path: it still receives every event, and the system discards every answer it
/// gives, so keyboard and mouse input stop for the whole login session until the
/// app quits. `AXIsProcessTrusted()` cannot be relied on to notice: on macOS 27
/// it can keep answering true after a revoke for as long as anyone waits.
/// `CGEvent.tapCreate` is the check that holds, since it fails while access is
/// gone.
///
/// So every Accessibility change (the `com.apple.accessibility.api` distributed
/// notification, posted when any app's permission changes) takes the taps down
/// at once, on the guard's own queue so a busy main thread cannot delay it, and
/// asks the app to rebuild them shortly after: no taps while access is gone,
/// live ones once it is back. It rebuilds twice, at 0.3s and 1.5s, because the
/// system can take a moment to apply the change and a tap built before it lands
/// is the dead one again. A rebuild costs milliseconds and these changes are
/// rare, so every one rebuilds, whichever app it was for.
///
/// No timer runs: the guard costs nothing until a permission changes.
///
/// Adopting it:
/// 1. Keep each tap in an `EventTapBox`, so `taps` can read it from the guard's
///    queue.
/// 2. Run each tap with `EventTapGuard.run(_:name:)` and stop it with
///    `EventTapGuard.stop(_:)`. A tap that is only invalidated stays enabled in
///    the event path: the system sends it the next event, waits out the tap
///    timeout and drops about a second of input. And a tap whose run loop runs
///    on a pooled GCD thread, stopped with a block queued on that run loop, can
///    leave the block queued for the next tap that lands on the same thread,
///    which then stops on its first turn and drops a second of input too.
/// 3. `rebuild` runs on the main thread. It stops what is left of the old taps
///    and creates new ones if the feature is on, there or on a thread of its
///    own. Creation returns nil while access is gone, which is fine: the next
///    change calls it again. The guard has already disabled and invalidated
///    the current taps when it runs.
/// 4. `.tapDisabledByUserInput` also reaches a tap's callback when it is
///    disabled on purpose. Don't re-enable a tap that is no longer valid
///    (`CFMachPortIsValid`), and don't let a health check re-enable one either.
/// 5. If the app already reads `AXIsProcessTrusted()` periodically, call
///    `accessLost()` when it reads false. One more way in, never the only one.
/// 6. Keep a strong reference to the guard, call `start()` once the taps are up
///    and `stop()` when the app stops tapping for good.
///
/// The distributed notification is observed with `.deliverImmediately`: AppKit
/// holds distributed notifications while an app is inactive, and a menu bar app
/// almost never is active.
/// `@unchecked Sendable`: the closures are immutable and `observing` and
/// `pendingRebuilds` are only touched on the main thread.
nonisolated final class EventTapGuard: NSObject, @unchecked Sendable {
    init(
        taps: @escaping @Sendable () -> [CFMachPort],
        rebuild: @escaping @MainActor () -> Void,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.taps = taps
        self.rebuild = rebuild
        self.log = log
    }

    static let accessibilityChanged = NSNotification.Name("com.apple.accessibility.api")
    static let rebuildDelays: [TimeInterval] = [0.3, 1.5]

    /// Run `tap` on a thread of its own and enable it. The thread ends when the
    /// tap is invalidated, which removes the run loop's only source.
    static func run(_ tap: CFMachPort, name: String) {
        guard let created = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else { return }
        nonisolated(unsafe) let source = created
        let thread = Thread {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CFRunLoopRun()
        }
        thread.name = name
        thread.qualityOfService = .userInteractive
        thread.start()
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    /// Take `tap` out of the event path for good: disable first, then
    /// invalidate. Safe from any thread.
    static func stop(_ tap: CFMachPort) {
        CGEvent.tapEnable(tap: tap, enable: false)
        CFMachPortInvalidate(tap)
    }

    func start() {
        guard !observing else { return }
        observing = true
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(accessibilityDidChange),
            name: Self.accessibilityChanged,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
    }

    func stop() {
        guard observing else { return }
        observing = false
        DistributedNotificationCenter.default().removeObserver(self, name: Self.accessibilityChanged, object: nil)
        DispatchQueue.main.async { self.cancelRebuilds() }
    }

    /// Take the taps down without waiting for a notification, for an app that
    /// has seen `AXIsProcessTrusted()` read false. Rebuilding is left to the
    /// app's own retry or the next permission change.
    func accessLost() {
        queue.async { self.takeDown("Accessibility reads as revoked") }
    }

    private let taps: @Sendable () -> [CFMachPort]
    private let rebuild: @MainActor () -> Void
    private let log: @Sendable (String) -> Void
    private let queue = DispatchQueue(label: "EventTapGuard", qos: .userInteractive)
    private var observing = false
    /// Main thread only, so a burst of notifications ends in one set of rebuilds.
    private var pendingRebuilds: [Dispatch.DispatchWorkItem] = []

    @objc private func accessibilityDidChange() {
        queue.async { self.takeDown("Accessibility permissions changed") }
        DispatchQueue.main.async { self.scheduleRebuilds() }
    }

    /// Disables and invalidates every live tap. Safe from any thread. Returns
    /// how many were live.
    @discardableResult
    private func takeDown(_ reason: String?) -> Int {
        let live = taps().filter { CFMachPortIsValid($0) }
        live.forEach(Self.stop)
        if let reason, !live.isEmpty {
            log("\(reason), \(live.count == 1 ? "event tap" : "\(live.count) event taps") removed so input keeps flowing")
        }
        return live.count
    }

    private func scheduleRebuilds() {
        cancelRebuilds()
        pendingRebuilds = Self.rebuildDelays.map { delay in
            let item = Dispatch.DispatchWorkItem { [weak self] in
                guard let self, observing else { return }
                takeDown(nil)
                MainActor.assumeIsolated { self.rebuild() }
                // Counted a moment later: an app may create its taps on a
                // thread of its own after `rebuild` returns.
                queue.asyncAfter(deadline: .now() + 0.25) {
                    let live = self.taps().filter { CFMachPortIsValid($0) }.count
                    self.log("event taps rebuilt after the permission change: \(live == 0 ? "none live, Accessibility is off or the feature is" : "\(live) live")")
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
            return item
        }
    }

    private func cancelRebuilds() {
        pendingRebuilds.forEach { $0.cancel() }
        pendingRebuilds = []
    }
}

/// A tap reference readable from any thread, for `EventTapGuard`'s `taps`.
nonisolated final class EventTapBox: @unchecked Sendable {
    var tap: CFMachPort? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            stored = newValue
        }
    }

    private let lock = NSLock()
    private var stored: CFMachPort?
}
