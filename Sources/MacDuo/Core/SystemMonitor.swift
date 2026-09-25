import AppKit

/// Observes system states during which the overlay must not run, and display reconfiguration.
@MainActor
final class SystemMonitor {
    enum Suspension: Hashable, CustomStringConvertible {
        case systemSleep
        case displaySleep
        case sessionInactive
        case screenLocked

        var description: String {
            switch self {
            case .systemSleep: String(localized: "system asleep")
            case .displaySleep: String(localized: "display asleep")
            case .sessionInactive: String(localized: "user session inactive")
            case .screenLocked: String(localized: "screen locked")
            }
        }
    }

    private(set) var suspensions: Set<Suspension> = []
    var onSuspensionsChange: ((Set<Suspension>, _ added: Suspension?) -> Void)?
    var onScreenConfigurationChange: (() -> Void)?

    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []

    func start() {
        guard tokens.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.willSleepNotification) { $0.insert(.systemSleep) }
        observe(workspace, NSWorkspace.didWakeNotification) { $0.remove(.systemSleep) }
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.insert(.displaySleep) }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.remove(.displaySleep) }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.insert(.sessionInactive) }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { $0.remove(.sessionInactive) }
        let distributed = DistributedNotificationCenter.default()
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.insert(.screenLocked) }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { $0.remove(.screenLocked) }

        let token = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onScreenConfigurationChange?() }
        }
        tokens.append((NotificationCenter.default, token))
    }

    func stop() {
        for (center, token) in tokens { center.removeObserver(token) }
        tokens.removeAll()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         _ change: @escaping @MainActor (inout Set<Suspension>) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                var updated = self.suspensions
                change(&updated)
                guard updated != self.suspensions else { return }
                let added = updated.subtracting(self.suspensions).first
                self.suspensions = updated
                self.onSuspensionsChange?(updated, added)
            }
        }
        tokens.append((center, token))
    }
}
