import SwiftUI

struct TargetEditor: View {
    @EnvironmentObject private var store: GameStore
    @Environment(\.dismiss) private var dismiss

    var existing: Target?
    var onFinish: (String?) -> Void

    @State private var title = ""
    @State private var kind = TargetKind.custom
    @State private var starts = Date()
    @State private var ends = Date()
    @State private var unitsGoal = ""
    @State private var requirements: [RequirementDraft] = [RequirementDraft()]
    @State private var message: String?

    var body: some View {
        ZStack {
            SystemBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    SystemTitle(text: existing == nil ? "New Target" : "Edit Target")
                        .padding(.top, 28)
                    SystemPanel {
                        VStack(alignment: .leading, spacing: 14) {
                            field("TITLE") {
                                TextField("Interview Prep", text: $title)
                                    .textFieldStyle(.plain)
                                    .foregroundStyle(.white)
                            }
                            field("KIND") {
                                Picker("Kind", selection: $kind) {
                                    ForEach(TargetKind.allCases, id: \.self) { item in
                                        Text(item.title).tag(item)
                                    }
                                }
                                .pickerStyle(.menu)
                                .tint(SystemTheme.cyan)
                            }
                            field("STARTS") {
                                DatePicker("Starts", selection: $starts, displayedComponents: .date)
                                    .labelsHidden()
                                    .datePickerStyle(.compact)
                                    .tint(SystemTheme.cyan)
                            }
                            field("ENDS") {
                                DatePicker("Ends", selection: $ends, displayedComponents: .date)
                                    .labelsHidden()
                                    .datePickerStyle(.compact)
                                    .tint(SystemTheme.cyan)
                            }
                            field("UNIT GOAL") {
                                TextField("Blank uses quota × days", text: $unitsGoal)
                                    .textFieldStyle(.plain)
                                    .foregroundStyle(.white)
                            }
                        }
                    }

                    ForEach($requirements) { $requirement in
                        SystemPanel {
                            VStack(alignment: .leading, spacing: 12) {
                                TextField("LeetCode Mediums", text: $requirement.title)
                                    .textFieldStyle(.plain)
                                    .foregroundStyle(.white)
                                Stepper(value: $requirement.quota, in: 1...500, step: 1) {
                                    Text("Quota \(requirement.quota)")
                                        .font(.subheadline.monospacedDigit())
                                        .foregroundStyle(.white)
                                }
                                .tint(SystemTheme.cyan)
                                Picker("Stat", selection: $requirement.stat) {
                                    ForEach(Stat.allCases, id: \.self) { stat in
                                        Text(stat.rawValue).tag(stat)
                                    }
                                }
                                .pickerStyle(.menu)
                                .tint(SystemTheme.cyan)
                                Picker("Verify", selection: $requirement.verification) {
                                    ForEach(VerificationMethod.allCases, id: \.self) { method in
                                        Text(method.rawValue).tag(method)
                                    }
                                }
                                .pickerStyle(.menu)
                                .tint(SystemTheme.cyan)
                                if requirements.count > 1 {
                                    Button("Remove") { requirements.removeAll { $0.id == requirement.id } }
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(SystemTheme.muted)
                                }
                            }
                        }
                    }

                    Button("ADD REQUIREMENT") {
                        requirements.append(RequirementDraft())
                    }
                    .font(.caption.weight(.bold))
                    .foregroundStyle(SystemTheme.muted)

                    Button("FILL INTERVIEW PREP") { fillInterviewPrep() }
                        .font(.caption.weight(.bold))
                        .foregroundStyle(SystemTheme.cyan)

                    if let message {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(SystemTheme.muted)
                    }

                    HStack {
                        Button("CANCEL") { dismiss() }
                        Spacer()
                        Button("SAVE") { save() }
                    }
                    .font(.caption.weight(.bold))
                    .tracking(1.2)
                    .foregroundStyle(SystemTheme.cyan)
                    .padding(.bottom, 28)
                }
                .padding(.horizontal, 22)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear(perform: load)
    }

    private func load() {
        guard let existing else {
            let today = QuestDay.date(from: QuestDay.key(for: .now)) ?? .now
            starts = today
            ends = QuestDay.date(from: QuestDay.key(byAddingDays: 13, to: QuestDay.key(for: today))) ?? today
            return
        }
        title = existing.title
        kind = existing.kind
        starts = QuestDay.date(from: existing.startsOn) ?? .now
        ends = QuestDay.date(from: existing.endsOn) ?? starts
        unitsGoal = existing.unitsGoal.map(String.init) ?? ""
        requirements = existing.dailyRequirements.map(RequirementDraft.init)
        if requirements.isEmpty { requirements = [RequirementDraft()] }
    }

    private func fillInterviewPrep() {
        let sample = Target.interviewPrep(starting: QuestDay.key(for: starts))
        title = sample.title
        kind = sample.kind
        ends = QuestDay.date(from: sample.endsOn) ?? ends
        unitsGoal = sample.unitsGoal.map(String.init) ?? ""
        requirements = sample.dailyRequirements.map(RequirementDraft.init)
    }

    private func save() {
        let parsedUnits = Int(unitsGoal.trimmingCharacters(in: .whitespaces))
        let target = Target(
            id: existing?.id ?? "tgt_\(UUID().uuidString.prefix(8))",
            title: title,
            kind: kind,
            status: existing?.status ?? .draft,
            startsOn: QuestDay.key(for: starts),
            endsOn: QuestDay.key(for: ends),
            dailyRequirements: requirements.map { $0.makeRequirement() },
            unitsGoal: parsedUnits,
            unitsDone: existing?.unitsDone ?? 0,
            daysCleared: existing?.daysCleared ?? 0,
            clearedDayKeys: existing?.clearedDayKeys ?? [],
            countedQuestIds: existing?.countedQuestIds ?? [],
            completionBonusGranted: existing?.completionBonusGranted ?? false
        )
        let result = store.saveTarget(target)
        if result == nil {
            onFinish("Saved. If the Target is active, swipe back to System.")
            dismiss()
        } else if result?.hasPrefix("Scheduled") == true {
            onFinish(result)
            dismiss()
        } else {
            message = result
        }
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption2.weight(.bold))
                .tracking(1.2)
                .foregroundStyle(SystemTheme.muted)
            content()
        }
    }
}

private struct RequirementDraft: Identifiable {
    var id = UUID().uuidString
    var title = ""
    var quota = 3
    var unit = "problems"
    var stat = Stat.INT
    var verification = VerificationMethod.manualConfirm
    var xp = 40

    init() {}

    init(_ requirement: TargetDailyRequirement) {
        id = requirement.id
        title = requirement.title
        quota = Int(requirement.quota.rounded())
        unit = requirement.unit
        stat = requirement.stat
        verification = requirement.verification
        xp = requirement.xp
    }

    func makeRequirement() -> TargetDailyRequirement {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return TargetDailyRequirement(
            id: id,
            title: name,
            quota: Double(max(quota, 1)),
            unit: unit.isEmpty ? "count" : unit,
            stat: stat,
            verification: verification,
            xp: xp
        )
    }
}
