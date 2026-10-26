import ServiceManagement
import SwiftUI

/// Menu-bar only (LSUIElement): no Dock icon and no window. It starts at login so every day is counted.
@main struct FocusTrackerApp: App {
    @State private var tracker = FocusTracker()

    init() {
        // Start at login the first time it runs. The menu can turn it off.
        if !UserDefaults.standard.bool(forKey: "loginItemOffered") {
            UserDefaults.standard.set(true, forKey: "loginItemOffered")
            try? SMAppService.mainApp.register()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            FocusMenu(tracker: tracker)
        } label: {
            Image(systemName: tracker.paused ? "eye.slash" : "eye")
        }
    }
}

private struct FocusMenu: View {
    let tracker: FocusTracker
    @State private var startsAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        let today = tracker.today
        Text("Today: \(Self.duration(today.screenMinutes)), social \(Self.duration(today.socialMinutes))")
        Text(syncLine)
        if tracker.browserBlocked {
            Text("Allow Automation for your browser in System Settings → Privacy & Security, or social sites do not count.")
        }
        Divider()
        Button("Sync Now") { tracker.syncNow() }
        Toggle("Start at Login", isOn: $startsAtLogin)
            .onChange(of: startsAtLogin) { _, on in
                if on { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
            }
        Divider()
        Button("Quit FocusTracker") {
            tracker.flush()
            NSApplication.shared.terminate(nil)
        }
    }

    private var syncLine: String {
        let waiting = tracker.pending.count
        if let error = tracker.syncError {
            return "iCloud: \(waiting) day\(waiting == 1 ? "" : "s") waiting (\(error))"
        }
        if let last = tracker.lastSync {
            return "iCloud: synced \(last.formatted(date: .omitted, time: .shortened))"
        }
        return waiting == 0 ? "iCloud: up to date" : "iCloud: \(waiting) day\(waiting == 1 ? "" : "s") waiting"
    }

    private static func duration(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(minutes % 60) min"
    }
}
