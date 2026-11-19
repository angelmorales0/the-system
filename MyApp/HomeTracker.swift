import CoreLocation
import Foundation

/// Watches one circle around home with iOS region monitoring. iOS wakes the app when the phone enters or leaves it,
/// also when the app is closed, and the tracker saves the time (see `HomeEvents`). It keeps no location trail:
/// only the home center and the enter and leave times.
@MainActor
final class HomeTracker: NSObject, CLLocationManagerDelegate {
    static let shared = HomeTracker()

    static let centerKey = "com.angelmorales.thesystem.homeCenter.v1"
    static let regionId = "the-system-home"
    /// Large enough for GPS drift inside a house or an apartment block.
    static let radiusMeters = 150.0

    private let manager = CLLocationManager()
    private var settingHome = false
    /// Called after each saved event, so the store can judge the row.
    var onEvent: (() -> Void)?
    /// Called when "Set home" ends: nil when it worked, else the reason.
    var onSetHome: ((String?) -> Void)?

    override private init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    }

    var isHomeSet: Bool { UserDefaults.standard.object(forKey: Self.centerKey) != nil }

    /// Starts the region again after a launch. iOS keeps it across launches, so this only repairs a lost one.
    func resume() {
        guard isHomeSet, let center = savedCenter else { return }
        startMonitoring(center)
    }

    /// Saves the current location as home. Asks for "Always" location access first.
    func setHomeHere() {
        settingHome = true
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestAlwaysAuthorization()
        case .authorizedWhenInUse:
            manager.requestAlwaysAuthorization()
            manager.requestLocation()
        case .authorizedAlways:
            manager.requestLocation()
        default:
            settingHome = false
            onSetHome?("Location access is off. Turn on Always for The System in Settings → Privacy → Location Services.")
        }
    }

    private var savedCenter: CLLocationCoordinate2D? {
        guard let pair = UserDefaults.standard.array(forKey: Self.centerKey) as? [Double], pair.count == 2 else { return nil }
        return CLLocationCoordinate2D(latitude: pair[0], longitude: pair[1])
    }

    private func startMonitoring(_ center: CLLocationCoordinate2D) {
        guard CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else { return }
        let region = CLCircularRegion(center: center, radius: Self.radiusMeters, identifier: Self.regionId)
        region.notifyOnEntry = true
        region.notifyOnExit = true
        manager.startMonitoring(for: region)
        manager.requestState(for: region)
    }

    private func record(inside: Bool) {
        let events = HomeEvents.load()
        // A state check repeats the last state often; save only a change.
        guard events.last?.inside != inside else { return }
        HomeEvents.append(HomeEvent(at: Date(), inside: inside))
        onEvent?()
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            guard self.settingHome else { return }
            switch manager.authorizationStatus {
            case .authorizedAlways, .authorizedWhenInUse:
                manager.requestLocation()
            case .denied, .restricted:
                self.settingHome = false
                self.onSetHome?("Location access is off. Turn on Always for The System in Settings → Privacy → Location Services.")
            default:
                break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            guard self.settingHome else { return }
            self.settingHome = false
            let center = location.coordinate
            UserDefaults.standard.set([center.latitude, center.longitude], forKey: Self.centerKey)
            self.startMonitoring(center)
            self.record(inside: true)
            self.onSetHome?(nil)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            guard self.settingHome else { return }
            self.settingHome = false
            self.onSetHome?("The location could not be read. Try again outside or near a window.")
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        guard region.identifier == Self.regionId else { return }
        Task { @MainActor in self.record(inside: true) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        guard region.identifier == Self.regionId else { return }
        Task { @MainActor in self.record(inside: false) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didDetermineState state: CLRegionState, for region: CLRegion) {
        guard region.identifier == Self.regionId, state != .unknown else { return }
        Task { @MainActor in self.record(inside: state == .inside) }
    }
}
