import SwiftUI

/// Additive sheet. Sets the emergency quest targets and runs a test of each one.
struct EmergencySettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: GameStore
    @State private var settings = EmergencySettings.standard
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            QuestSheet(title: "Emergency quests") {
                VStack(alignment: .leading, spacing: 12) {
                    timePicker("Earliest start", minutes: $settings.earliestStart)
                    note("No emergency quest starts before this time. Bedtime starts at this time or later.")
                }

                QuestSectionTitle(text: "Lights Out")
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Bedtime lockdown", isOn: $settings.bedtimeEnabled)
                    timePicker("Bedtime", minutes: $settings.bedtimeStart)
                    timePicker("Wake time", minutes: $settings.wakeTime)
                    Stepper("Use allowed: \(settings.bedtimeGraceMinutes) min", value: $settings.bedtimeGraceMinutes, in: 1...30)
                    Stepper("Lockdown: \(settings.lockdownMinutes) min", value: $settings.lockdownMinutes, in: 5...60, step: 5)
                    note(bedtimeFooter)
                }

                QuestSectionTitle(text: "Movement")
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Step check", isOn: $settings.stepsEnabled)
                    timePicker("Check time", minutes: $settings.stepCheckTime)
                    Stepper("Minimum: \(settings.minimumSteps.formatted()) steps", value: $settings.minimumSteps, in: 500...20_000, step: 500)
                    Stepper("Walk: \(settings.walkSteps.formatted()) steps", value: $settings.walkSteps, in: 500...10_000, step: 250)
                    Stepper("Time limit: \(settings.walkLimitMinutes) min", value: $settings.walkLimitMinutes, in: 15...180, step: 15)
                    note("After \(Self.timeString(EmergencyRules.stepCheckMinute(settings))), fewer than \(settings.minimumSteps.formatted()) steps starts a walk. Your distractor apps lock until you walk \(settings.walkSteps.formatted()) steps. A miss opens a penalty tomorrow. iOS checks Health about once an hour in the background.")
                }

                QuestSectionTitle(text: "Restore Flexibility")
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Stretch check", isOn: $settings.stretchEnabled)
                    timePicker("Check time", minutes: $settings.stretchCheckTime)
                    Stepper("Time limit: \(settings.stretchLimitMinutes) min", value: $settings.stretchLimitMinutes, in: 15...180, step: 15)
                    note("At \(Self.timeString(EmergencyRules.stretchCheckMinute(settings))), an open Stretching quest starts this emergency. Your distractor apps lock until \(Int(DailyStretch.minutes)) minutes of stretches are logged: timed stretch sets in Hevy, or a Flexibility, Yoga, or Cooldown workout in Apple Health. A miss after \(settings.stretchLimitMinutes) minutes opens a penalty tomorrow.")
                }

                QuestSectionTitle(text: "Test")
                VStack(alignment: .leading, spacing: 12) {
                    VStack(spacing: 10) {
                        testButton("Test Lights Out") { store.startEmergencyTest(.bedtimeLockdown) }
                        testButton("Test Movement") { store.startEmergencyTest(.lowSteps) }
                        testButton("Test Restore Flexibility") { store.startEmergencyTest(.skippedStretch) }
                    }
                    .disabled(store.emergency != nil)
                    note("A test uses these targets. You can end it early, and it never opens a penalty.")
                }
            }
            .font(.subheadline)
            .tint(SystemTheme.accent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .onAppear {
                guard !loaded else { return }
                settings = store.emergencySettings
                loaded = true
            }
            .onChange(of: settings) { _, next in
                guard loaded else { return }
                store.updateEmergencySettings(next)
            }
        }
    }

    private var bedtimeFooter: String {
        let start = Self.timeString(EmergencyRules.effectiveBedtimeStart(settings))
        let wake = Self.timeString(settings.wakeTime)
        var text = "From \(start) to \(wake), \(settings.bedtimeGraceMinutes) min on your distractor apps locks every app for \(settings.lockdownMinutes) min. Calls and emergency SOS stay open."
        if !store.snapshot.hasDistractorSelection {
            text += " Choose your distractor apps first (Status → Distractor shields). To watch all phone use, select every category there."
        }
        return text
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(SystemTheme.muted)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Boxed like the quest window's header boxes.
    private func testButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
            dismiss()
        } label: {
            Text(title)
                .font(.footnote)
                .tracking(0.8)
                .frame(maxWidth: .infinity, minHeight: 38)
                .overlay { Rectangle().stroke(QuestLight.ink.opacity(0.6), lineWidth: 0.8) }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func timePicker(_ title: String, minutes: Binding<Int>) -> some View {
        DatePicker(title, selection: Binding(
            get: { Self.date(minutes.wrappedValue) },
            set: { minutes.wrappedValue = EmergencyRules.minuteOfDay($0) }
        ), displayedComponents: .hourAndMinute)
    }

    private static func date(_ minutes: Int) -> Date {
        QuestDay.calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: .now) ?? .now
    }

    private static func timeString(_ minutes: Int) -> String {
        date(minutes).formatted(date: .omitted, time: .shortened)
    }
}

#Preview {
    EmergencySettingsSheet()
        .environmentObject(GameStore(persistence: .memory))
}
