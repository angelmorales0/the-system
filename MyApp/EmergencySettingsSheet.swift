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
                }

                QuestSectionTitle(text: "Movement")
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Step check", isOn: $settings.stepsEnabled)
                    timePicker("Check time", minutes: $settings.stepCheckTime)
                    Stepper("Minimum: \(settings.minimumSteps.formatted()) steps", value: $settings.minimumSteps, in: 500...20_000, step: 500)
                    Stepper("Walk: \(settings.walkSteps.formatted()) steps", value: $settings.walkSteps, in: 500...10_000, step: 250)
                    Stepper("Time limit: \(settings.walkLimitMinutes) min", value: $settings.walkLimitMinutes, in: 15...180, step: 15)
                }

                QuestSectionTitle(text: "Restore Flexibility")
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Stretch check", isOn: $settings.stretchEnabled)
                    timePicker("Check time", minutes: $settings.stretchCheckTime)
                    Stepper("Time limit: \(settings.stretchLimitMinutes) min", value: $settings.stretchLimitMinutes, in: 15...180, step: 15)
                }

                QuestSectionTitle(text: "Test")
                VStack(alignment: .leading, spacing: 12) {
                    VStack(spacing: 10) {
                        testButton("Test Movement") { store.startEmergencyTest(.lowSteps) }
                        testButton("Test Restore Flexibility") { store.startEmergencyTest(.skippedStretch) }
                    }
                    .disabled(store.emergency != nil)
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
