//
//  EventTapGuard.swift
//
//  Self-contained (AppKit, CoreGraphics and notify only), so the same file can be
//  copied into any app that runs an active CGEvent tap. `nonisolated` keeps it
//  off the main actor in targets that make that the default isolation, and
//  `Dispatch.DispatchWorkItem` is spelled out for apps that define their own.
//

import AppKit
import CoreGraphics
import Dispatch
import notify

// MARK: - EventTapGuard

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
/// macOS can also revoke Accessibility without that notification: `tccutil
/// reset`, a configuration profile, a reset of the privacy database. On macOS
/// 27.2, `AXIsProcessTrusted`, `CGPreflightPostEventAccess` and AX
/// reads then kept answering as granted for as long as the revoke lasted, and
/// the taps blocked every key, click and scroll they covered. tccd posts the
/// `com.apple.tcc.access.changed` Darwin notification within milliseconds of
/// any privacy change, for any app and any service. So on that one the guard
/// asks whether an active tap can still be created, a few times over the next
/// seconds because the WindowServer applies the change about a second later.
/// It takes the taps down only when creation fails, and asks for a rebuild
/// once a later change makes creation work again.
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
///    disabled on purpose. Re-enable a tap from a callback or a health check
///    with `EventTapGuard.enable(_:)` and probe it with `isEnabled(_:)`, never
///    with `CGEvent.tapEnable` directly: those skip a tap that is no longer
///    valid, and wait while another thread is stopping it (see `whileLive`).
/// 5. If the app already reads `AXIsProcessTrusted()` periodically, call
///    `accessLost()` when it reads false. One more way in, never the only one.
/// 6. Keep a strong reference to the guard, call `start()` once the taps are up
///    and `stop()` when the app stops tapping for good.
///
/// The distributed notification is observed with `.deliverImmediately`: AppKit
/// holds distributed notifications while an app is inactive, and a menu bar app
/// almost never is active.
/// `@unchecked Sendable`: the closures are immutable, `observing`,
/// `pendingRebuilds`, `pendingChecks` and `privacyToken` are only touched on
/// the main thread, and `revokedTapsDown` only on `checkQueue`.
final nonisolated class EventTapGuard: NSObject, @unchecked Sendable {
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
    /// Posted by tccd for every privacy change (see the type's comment).
    static let privacyChanged = "com.apple.tcc.access.changed"
    /// The WindowServer refused new taps about 1 to 3 seconds after the
    /// change, so the check runs until 4 seconds after it.
    static let privacyCheckDelays: [TimeInterval] = [0.3, 1, 2, 4]

    /// Whether macOS lets this app create an active tap, which it refuses while
    /// Accessibility is gone. The probe takes an event type that a session
    /// barely sees and lives for a fraction of a millisecond.
    static func activeTapAllowed() -> Bool {
        guard let probe = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(1) << CGEventMask(NX_KITDEFINED),
            callback: { _, _, event, _ in Unmanaged.passUnretained(event) },
            userInfo: nil
        ) else { return false }
        stop(probe)
        return true
    }

    /// Run `tap` on a thread of its own and enable it. The thread ends when
    /// `stop` invalidates the tap and stops the thread's run loop.
    static func run(_ tap: CFMachPort, name: String) {
        guard let created = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else { return }
        nonisolated(unsafe) let source = created
        nonisolated(unsafe) let port = tap
        let thread = Thread {
            guard let runLoop = CFRunLoopGetCurrent(), register(port, on: runLoop) else { return }
            CFRunLoopAddSource(runLoop, source, .commonModes)
            CFRunLoopRun()
            unregister(port)
        }
        thread.name = name
        thread.qualityOfService = .userInteractive
        thread.start()
        enable(tap)
    }

    /// Take `tap` out of the event path for good: disable first, then
    /// invalidate. Safe from any thread.
    static func stop(_ tap: CFMachPort) {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard CFMachPortIsValid(tap) else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        CFMachPortInvalidate(tap)
        // The invalidation takes the source out of the run loop without waking
        // it, and a thread that was waiting for the next event kept waiting, one
        // more thread for every tap that was stopped.
        if let runLoop = runLoops.first(where: { $0.tap === tap })?.runLoop {
            CFRunLoopStop(runLoop)
        }
    }

    /// Turn `tap` on, unless it was invalidated. Safe from any thread.
    static func enable(_ tap: CFMachPort) {
        whileLive(tap) { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    /// Whether the WindowServer has `tap` enabled, or nil once it was
    /// invalidated. A synchronous WindowServer round trip. Safe from any thread.
    static func isEnabled(_ tap: CFMachPort) -> Bool? {
        whileLive(tap) { CGEvent.tapIsEnabled(tap: tap) }
    }

    /// Runs `body` while `tap` can't be invalidated by `stop`, and only if it
    /// is still valid. Every `CGEvent.tapEnable` or `CGEvent.tapIsEnabled` on a
    /// tap that another thread may stop goes through here.
    ///
    /// SkyLight keeps a tap's state in the port's context, and invalidating the
    /// port frees that state. Both calls read it, wait for the WindowServer's
    /// answer and then read it again, so a tap invalidated on another thread
    /// during that wait left them reading freed memory: EXC_BAD_ACCESS in
    /// `SLEventTapEnable` from a health check or a re-enable in a callback
    /// while the taps were being rebuilt. `CFMachPortIsValid` alone can't
    /// prevent it, because the port can be invalidated right after the check.
    /// After the invalidation the calls find no state and do nothing, so only
    /// the overlap needs the lock.
    @discardableResult
    static func whileLive<T>(_ tap: CFMachPort, _ body: () -> T) -> T? {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard CFMachPortIsValid(tap) else { return nil }
        return body()
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
        var token: Int32 = 0
        if notify_register_dispatch(Self.privacyChanged, &token, .main, { [weak self] _ in self?.scheduleChecks() }) == NOTIFY_STATUS_OK {
            privacyToken = token
        }
    }

    func stop() {
        guard observing else { return }
        observing = false
        DistributedNotificationCenter.default().removeObserver(self, name: Self.accessibilityChanged, object: nil)
        DispatchQueue.main.async {
            if let token = self.privacyToken {
                notify_cancel(token)
                self.privacyToken = nil
            }
            self.cancelRebuilds()
            self.cancelChecks()
        }
    }

    /// Take the taps down without waiting for a notification, for an app that
    /// has seen `AXIsProcessTrusted()` read false. Rebuilding is left to the
    /// app's own retry or the next permission change.
    func accessLost() {
        queue.async { self.takeDown("Accessibility reads as revoked") }
    }

    /// Held for one tap call or one invalidation at a time, never while waiting
    /// on the main thread.
    private static let lifecycleLock = NSLock()
    /// The run loop of each tap started with `run`, for `stop`. Under
    /// `lifecycleLock`.
    nonisolated(unsafe) private static var runLoops: [(tap: CFMachPort, runLoop: CFRunLoop)] = []

    /// Records the run loop of a tap's thread, unless the tap was stopped
    /// before the thread started.
    private static func register(_ tap: CFMachPort, on runLoop: CFRunLoop) -> Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard CFMachPortIsValid(tap) else { return false }
        runLoops.append((tap, runLoop))
        return true
    }

    private static func unregister(_ tap: CFMachPort) {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        runLoops.removeAll { $0.tap === tap }
    }

    private let taps: @Sendable () -> [CFMachPort]
    private let rebuild: @MainActor () -> Void
    private let log: @Sendable (String) -> Void
    private let queue = DispatchQueue(label: "EventTapGuard", qos: .userInteractive)
    private var observing = false
    /// Main thread only, so a burst of notifications ends in one set of rebuilds.
    private var pendingRebuilds: [Dispatch.DispatchWorkItem] = []
    /// Main thread only, for the same reason.
    private var pendingChecks: [Dispatch.DispatchWorkItem] = []
    private var privacyToken: Int32?
    /// The probe runs here and not on `queue`, so a WindowServer call that
    /// hangs can't hold up a take-down.
    private let checkQueue = DispatchQueue(label: "EventTapGuard check", qos: .userInitiated)
    /// The taps were taken down because a probe failed. `checkQueue` only.
    private var revokedTapsDown = false

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

    /// Main thread: a privacy change, for any app or service. Checks over the
    /// next seconds, and a new change starts the checks over.
    private func scheduleChecks() {
        cancelChecks()
        pendingChecks = Self.privacyCheckDelays.map { delay in
            let item = Dispatch.DispatchWorkItem { [weak self] in
                guard let self, observing else { return }
                checkQueue.async { self.checkAccess() }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
            return item
        }
    }

    private func cancelChecks() {
        pendingChecks.forEach { $0.cancel() }
        pendingChecks = []
    }

    /// `checkQueue`: takes the taps down when a tap can't be created, and asks
    /// for them back once one can.
    private func checkAccess() {
        if Self.activeTapAllowed() {
            guard revokedTapsDown else { return }
            revokedTapsDown = false
            log("Accessibility is back, rebuilding the event taps")
            DispatchQueue.main.async {
                guard self.observing else { return }
                MainActor.assumeIsolated { self.rebuild() }
            }
        } else if takeDown("Accessibility was revoked without the change notification") > 0 {
            revokedTapsDown = true
        }
    }
}

// MARK: - EventTapBox

/// A tap reference readable from any thread, for `EventTapGuard`'s `taps`.
final nonisolated class EventTapBox: @unchecked Sendable {
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
