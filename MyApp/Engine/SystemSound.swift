import AVFoundation
import Foundation

/// The System's sound cues. Each case is one file in `Resources/Sounds`, trimmed from the
/// raw library in `docs/sound-library` and normalized to the same loudness.
/// Play a cue from a store method or a button action, never from a view body.
enum SystemSound: String, CaseIterable {
    /// The app opens.
    case launch
    /// A new day's quests arrive while the app is open.
    case newDay = "new-day"
    /// A System window (sheet) opens.
    case systemOpen = "system-open"
    /// A System window closes.
    case systemClose = "system-close"
    /// One quest row is verified done.
    case questComplete = "quest-complete"
    /// A tap the System refused, a quest that failed, or a purchase the shop refused.
    case questFail = "quest-fail"
    /// A timed quest starts counting.
    case timerStart = "timer-start"
    /// The last required quest of the day is done by real work.
    case dayClear = "day-clear"
    /// The STATUS level went up.
    case levelUp = "level-up"
    /// Gold or a token arrives.
    case reward
    /// The shop sold something.
    case purchase
    /// A potion is drunk.
    case potion
    /// A Full Recovery token is spent.
    case fullRecovery = "full-recovery"
    /// A hidden quest's reveal window appears.
    case hiddenQuest = "hidden-quest"
    /// The penalty window arrives.
    case penaltyOpen = "penalty-open"
    /// The penalty run is verified and the window lifts.
    case penaltyCleared = "penalty-cleared"
    /// An emergency quest starts, HP turns critical, or fatigue turns red.
    case warning
    case emergencyComplete = "emergency-complete"
    case emergencyFailed = "emergency-failed"

    /// A major cue silences whatever else is playing. A minor cue layers on top.
    var isMajor: Bool {
        switch self {
        case .dayClear, .levelUp, .fullRecovery, .hiddenQuest, .penaltyOpen, .penaltyCleared,
             .emergencyComplete, .emergencyFailed, .newDay, .reward:
            return true
        default:
            return false
        }
    }

    func play() {
        SoundPlayer.shared.play(self)
    }
}

/// Loads each cue once and plays it on demand. Silent in SwiftUI previews and when the Sound setting is off.
@MainActor
final class SoundPlayer {
    static let shared = SoundPlayer()
    /// The Sound switch on the settings sheet. Absent means on.
    static let enabledKey = "soundEnabled"

    private var players: [SystemSound: AVAudioPlayer] = [:]
    private var sessionReady = false
    /// A preview would play on the Mac for no one.
    private let inPreview = ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"

    private var enabled: Bool {
        !inPreview && (UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true)
    }

    func play(_ sound: SystemSound) {
        guard enabled, let player = player(for: sound) else { return }
        prepareSession()
        if sound.isMajor {
            for (other, playing) in players where other != sound && playing.isPlaying {
                playing.stop()
            }
        }
        player.currentTime = 0
        player.play()
    }

    private func player(for sound: SystemSound) -> AVAudioPlayer? {
        if let cached = players[sound] { return cached }
        // Synchronized Xcode groups may copy Resources/Sounds into the bundle root or keep the folders.
        let urls = [
            Bundle.main.url(forResource: sound.rawValue, withExtension: "m4a"),
            Bundle.main.url(forResource: sound.rawValue, withExtension: "m4a", subdirectory: "Sounds"),
            Bundle.main.url(forResource: sound.rawValue, withExtension: "m4a", subdirectory: "Resources/Sounds"),
        ]
        guard let url = urls.compactMap({ $0 }).first,
              let player = try? AVAudioPlayer(contentsOf: url) else { return nil }
        player.prepareToPlay()
        players[sound] = player
        return player
    }

    private func prepareSession() {
        guard !sessionReady else { return }
        sessionReady = true
        #if !os(macOS)
        // Ambient: the silent switch mutes the cues, and they mix with the player's own music.
        try? AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
    }
}

/// Turns one snapshot change into its cues, so every path that changes the snapshot sounds the same:
/// a tap, a timer, a connected verifier, or a refresh.
enum SoundCues {
    static func sounds(from old: GameSnapshot, to new: GameSnapshot) -> [SystemSound] {
        var cues: [SystemSound] = []
        // A new day replaces the quests. Its own cue plays from `refreshForToday`.
        if old.bundle.dayKey == new.bundle.dayKey {
            let before = Dictionary(old.bundle.quests.map { ($0.id, $0.status) }, uniquingKeysWith: { first, _ in first })
            var completed = false
            var failed = false
            for quest in new.bundle.quests {
                let was = before[quest.id]
                if quest.status == .completed, was != .completed, !quest.skippedWithPotion { completed = true }
                if quest.status == .failed, was != .failed { failed = true }
            }
            if completed, old.missesRequiredSet, !new.missesRequiredSet {
                cues.append(.dayClear)
            } else if completed {
                cues.append(.questComplete)
            }
            if failed { cues.append(.questFail) }
        }
        if old.player.penaltyOpen, !new.player.penaltyOpen {
            cues.append(.penaltyCleared)
        }
        if let before = old.hitPoints, let after = new.hitPoints,
           !HitPoints.isCritical(current: Int(before.current), max: before.max),
           HitPoints.isCritical(current: Int(after.current), max: after.max) {
            cues.append(.warning)
        } else if let before = old.fatigue, let after = new.fatigue,
                  !Fatigue.isRed(Int(before.value.rounded())), Fatigue.isRed(Int(after.value.rounded())) {
            cues.append(.warning)
        }
        return cues
    }
}
