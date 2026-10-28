import ServiceManagement
import SwiftUI

/// Menu-bar only (LSUIElement): no Dock icon. It starts at login so every day is counted.
@main struct FocusTrackerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Start at login the first time it runs. The menu can turn it off.
        if !UserDefaults.standard.bool(forKey: "loginItemOffered") {
            UserDefaults.standard.set(true, forKey: "loginItemOffered")
            try? SMAppService.mainApp.register()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            FocusMenu(tracker: appDelegate.tracker, showSetup: appDelegate.showSetup)
        } label: {
            Image(systemName: appDelegate.tracker.paused ? "eye.slash" : "eye")
        }
    }
}

/// Opening the app again (Finder, Spotlight, Launchpad) shows Setup, because a menu-bar app has no Dock icon
/// and its eye icon can hide behind the notch. The first launch also shows Setup until it has an address and token.
final class AppDelegate: NSObject, NSApplicationDelegate {
    let tracker = FocusTracker()
    private var setupWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !tracker.isSetUp { showSetup() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSetup()
        return true
    }

    func showSetup() {
        if setupWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SetupView(tracker: tracker)))
            window.title = "FocusTracker Setup"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            setupWindow = window
        }
        NSApplication.shared.activate()
        setupWindow?.makeKeyAndOrderFront(nil)
    }
}

private struct FocusMenu: View {
    let tracker: FocusTracker
    let showSetup: () -> Void
    @State private var startsAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Text("Today: \(Self.duration(tracker.todayMinutes))")
        Text(statusLine)
        Divider()
        Button("Set Up…", action: showSetup)
        Button("Send Now") { tracker.sendNow() }
            .disabled(!tracker.isSetUp)
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

    private var statusLine: String {
        if !tracker.isSetUp { return "Not set up: choose Set Up…" }
        if let error = tracker.sendError { return "Not sent: \(error)" }
        if let last = tracker.lastSent { return "Sent \(last.formatted(date: .omitted, time: .shortened))" }
        return "Waiting to send"
    }

    static func duration(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(minutes % 60) min"
    }
}

/// The Worker address and token. "Save and Test" checks the network first, then the token.
private struct SetupView: View {
    let tracker: FocusTracker
    @State private var endpoint = UserDefaults.standard.string(forKey: TrackerSettings.endpointKey) ?? ""
    @State private var token = UserDefaults.standard.string(forKey: TrackerSettings.tokenKey) ?? ""
    @State private var result = ""
    @State private var testing = false

    var body: some View {
        Form {
            TextField("Worker address", text: $endpoint, prompt: Text("https://screentime.<you>.workers.dev"))
            SecureField("Token", text: $token)
            HStack {
                Button("Save and Test") {
                    let settings = TrackerSettings(endpoint: endpoint, token: token)
                    settings.save()
                    testing = true
                    Task {
                        result = await TrackerClient.test(settings)
                        testing = false
                        tracker.sendNow()
                    }
                }
                .disabled(testing)
                if testing { ProgressView().controlSize(.small) }
            }
            if !result.isEmpty {
                Text(result).fixedSize(horizontal: false, vertical: true)
            }
            Text("Every Mac counts as work. Only the minute total for each day is sent: no app names, windows, or websites.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 320)
    }
}
