import SwiftUI

struct SystemView: View {
    @EnvironmentObject private var store: GameStore
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        ZStack {
            QuestBackdrop()
            GeometryReader { proxy in
                ScrollView(showsIndicators: false) {
                    QuestHologram {
                        questContent
                            .padding(.horizontal, 34)
                            .padding(.top, 36)
                            .padding(.bottom, 30)
                            .frame(minHeight: typeSize.isAccessibilitySize ? 900 : max(620, min(proxy.size.height * 0.87, 710)))
                    }
                    .frame(maxWidth: 460)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 28)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: proxy.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
    }

    private var questContent: some View {
        VStack(spacing: 0) {
            QuestInfoHeader()
            Spacer(minLength: 28)
            Text("[Daily Quest: \(store.bundle.headerLine)\nhas arrived.]")
                .font(.system(.subheadline, design: .default).weight(.regular))
                .lineSpacing(5)
                .multilineTextAlignment(.center)
                .foregroundStyle(QuestLight.ink)
                .shadow(color: QuestLight.blue.opacity(0.7), radius: 5)
                .fixedSize(horizontal: false, vertical: true)

            if let banner = store.targetBanner {
                Text(banner)
                    .font(.caption2.weight(.semibold))
                    .tracking(0.6)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(QuestLight.cyan)
                    .padding(.top, 8)
            }

            Spacer(minLength: 35)
            VStack(spacing: 3) {
                Text("GOAL")
                    .font(.system(.title2, design: .default).weight(.medium))
                    .tracking(1.3)
                    .foregroundStyle(QuestLight.ink)
                    .shadow(color: QuestLight.cyan, radius: 7)
                Rectangle().fill(QuestLight.ink.opacity(0.85)).frame(width: 59, height: 1)
                Rectangle().fill(QuestLight.ink.opacity(0.48)).frame(width: 59, height: 0.5)
            }
            .accessibilityAddTraits(.isHeader)

            Spacer(minLength: 23)
            VStack(spacing: 1) {
                ForEach(store.goalQuests) { quest in
                    Button {
                        store.handleQuestTap(id: quest.id)
                    } label: {
                        HStack(spacing: 11) {
                            Text(quest.kind == .targetInjection ? "⟪TARGET⟫ \(quest.title)" : quest.title)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(store.rowLabel(for: quest))
                                .monospacedDigit()
                                .fixedSize(horizontal: true, vertical: false)
                            QuestCheckbox(checked: quest.status == .completed)
                                .frame(width: 16, height: 17)
                        }
                        .font(.subheadline)
                        .foregroundStyle(QuestLight.ink)
                        .shadow(color: QuestLight.cyan.opacity(0.6), radius: 5)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(quest.title)
                    .accessibilityValue(store.accessibilityValue(for: quest))
                    .accessibilityHint(questRowHint(quest))
                }
            }

            if let note = store.verificationNote, !note.isEmpty {
                Text(note)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(QuestLight.ink.opacity(0.8))
                    .padding(.top, 14)
            }

            Spacer(minLength: 38)
            Text(warning)
                .font(.system(.footnote, design: .default))
                .lineSpacing(9)
                .multilineTextAlignment(.center)
                .foregroundStyle(QuestLight.ink)
                .shadow(color: QuestLight.blue.opacity(0.7), radius: 6)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 22)
            QuestSignalRing()
                .frame(width: 43, height: 43)
        }
    }

    private var warning: AttributedString {
        var text = AttributedString("WARNING: " + store.bundle.warningCopy)
        if let range = text.range(of: "penalty", options: .caseInsensitive) {
            text[range].foregroundColor = Color(red: 1, green: 0.12, blue: 0.32)
        }
        return text
    }
}

private func questRowHint(_ quest: Quest) -> String {
    switch quest.verification.method {
    case .timerSession:
        return "Starts the in-app timer"
    case .manualConfirm:
        return "Confirms this quest"
    default:
        return "Checks this quest on this device"
    }
}

// This screen has its own holographic treatment; the shared panels retain their styling.
private enum QuestLight {
    static let ink = Color(red: 0.87, green: 0.97, blue: 1)
    static let cyan = Color(red: 0.20, green: 0.80, blue: 1)
    static let blue = Color(red: 0.08, green: 0.42, blue: 1)
}

private struct QuestBackdrop: View {
    var body: some View {
        ZStack {
            Color(red: 0.008, green: 0.014, blue: 0.038)
            LinearGradient(colors: [Color(red: 0.01, green: 0.02, blue: 0.07),
                                    Color(red: 0.008, green: 0.014, blue: 0.038),
                                    Color(red: 0.015, green: 0.04, blue: 0.10)],
                           startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Color(red: 0.12, green: 0.70, blue: 1).opacity(0.26), .clear],
                           center: .topTrailing, startRadius: 0, endRadius: 330)
            RadialGradient(colors: [Color.indigo.opacity(0.34), .clear],
                           center: .bottomLeading, startRadius: 20, endRadius: 380)
            QuestBackdropThreads().opacity(0.58)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct QuestBackdropThreads: View {
    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            Path { path in
                path.move(to: CGPoint(x: -40, y: height * 0.20))
                path.addCurve(to: CGPoint(x: width + 50, y: height * 0.48), control1: CGPoint(x: width * 0.22, y: height * 0.05), control2: CGPoint(x: width * 0.62, y: height * 0.73))
                path.move(to: CGPoint(x: -25, y: height * 0.70))
                path.addCurve(to: CGPoint(x: width + 25, y: height * 0.25), control1: CGPoint(x: width * 0.35, y: height * 0.48), control2: CGPoint(x: width * 0.64, y: height * 0.60))
                path.move(to: CGPoint(x: width * 0.08, y: height + 20))
                path.addCurve(to: CGPoint(x: width * 0.92, y: -20), control1: CGPoint(x: width * 0.22, y: height * 0.60), control2: CGPoint(x: width * 0.74, y: height * 0.47))
            }
            .stroke(LinearGradient(colors: [.clear, SystemTheme.cyan.opacity(0.40), Color.indigo.opacity(0.54), .clear], startPoint: .leading, endPoint: .trailing), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            .blur(radius: 3)
        }
    }
}


private struct QuestInfoHeader: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 29, weight: .light))
                .frame(width: 40, height: 40)
                .overlay { Rectangle().stroke(QuestLight.ink.opacity(0.48), lineWidth: 0.6) }
                .accessibilityHidden(true)
            Text("QUEST INFO")
                .font(.system(size: 20, weight: .regular))
                .tracking(2.3)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .overlay { Rectangle().stroke(QuestLight.ink.opacity(0.43), lineWidth: 0.6) }
                .accessibilityAddTraits(.isHeader)
        }
        .foregroundStyle(QuestLight.ink)
        .background(QuestLight.cyan.opacity(0.025))
        .shadow(color: QuestLight.cyan.opacity(0.85), radius: 7)
    }
}

private struct QuestCheckbox: View {
    let checked: Bool
    var body: some View {
        ZStack {
            // The tiny break in the upper-right corner echoes the projected reference UI.
            Path { p in
                p.move(to: CGPoint(x: 11, y: 1))
                p.addLine(to: CGPoint(x: 1, y: 1))
                p.addLine(to: CGPoint(x: 1, y: 16))
                p.addLine(to: CGPoint(x: 15, y: 16))
                p.addLine(to: CGPoint(x: 15, y: 7))
            }.stroke(QuestLight.ink.opacity(0.85), lineWidth: 1)
            if checked {
                Image(systemName: "checkmark")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color(red: 0.22, green: 1, blue: 0.75))
                    .shadow(color: .cyan, radius: 4)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct QuestSignalRing: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var visible = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 12,
                                paused: reduceMotion || scenePhase != .active || !visible)) { timeline in
            let phase = reduceMotion ? 0 : Int(timeline.date.timeIntervalSinceReferenceDate * 7) % 28
            Canvas { context, size in
                for index in 0..<28 {
                    var segment = context
                    segment.translateBy(x: size.width / 2, y: size.height / 2)
                    segment.rotate(by: .degrees(Double(index) * 360 / 28))
                    let rect = CGRect(x: -1.15, y: -size.height / 2 + 1, width: 2.3, height: 5.3)
                    let path = Path(roundedRect: rect, cornerRadius: 0.8)
                    let lit = (index + phase) % 28 > 19
                    segment.fill(path, with: .color(QuestLight.ink.opacity(lit ? 0.9 : 0.05)))
                    segment.stroke(path, with: .color(QuestLight.ink.opacity(lit ? 1 : 0.4)), lineWidth: 0.5)
                }
            }
        }
        .shadow(color: QuestLight.cyan.opacity(0.8), radius: 4)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { visible = true }
        .onDisappear { visible = false }
    }
}

private struct QuestHologram<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity)
            .background {
                // The clear notches reveal the existing blue scene beneath the glass.
                LinearGradient(colors: [Color(red: 0.026, green: 0.085, blue: 0.12).opacity(0.88),
                                        Color(red: 0.024, green: 0.063, blue: 0.088).opacity(0.81),
                                        Color(red: 0.020, green: 0.065, blue: 0.10).opacity(0.87)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .clipShape(QuestGlassOutline())
                QuestCircuitry()
                    .clipShape(QuestGlassOutline())
            }
            .overlay { QuestFrame().allowsHitTesting(false).accessibilityHidden(true) }
    }
}

private struct QuestGlassOutline: Shape {
    func path(in r: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: 8, y: 0))
            p.addLine(to: CGPoint(x: r.width - 8, y: 0))
            p.addLine(to: CGPoint(x: r.width - 3, y: 16))
            // Deliberately uneven interruptions, instead of a regular dashed border.
            for (fraction, inset) in [(0.13, 3.0), (0.15, 13.0), (0.21, 13.0), (0.23, 4.0),
                                      (0.43, 4.0), (0.45, 12.0), (0.48, 12.0), (0.50, 3.0),
                                      (0.74, 3.0), (0.76, 14.0), (0.83, 14.0), (0.85, 4.0)] {
                p.addLine(to: CGPoint(x: r.width - inset, y: r.height * fraction))
            }
            p.addLine(to: CGPoint(x: r.width - 5, y: r.height - 8))
            p.addLine(to: CGPoint(x: 8, y: r.height))
            for (fraction, inset) in [(0.97, 5.0), (0.87, 5.0), (0.85, 12.0), (0.80, 12.0),
                                      (0.78, 3.0), (0.56, 3.0), (0.54, 13.0), (0.50, 13.0),
                                      (0.48, 4.0), (0.25, 4.0), (0.23, 12.0), (0.19, 12.0), (0.17, 3.0)] {
                p.addLine(to: CGPoint(x: inset, y: r.height * fraction))
            }
            p.closeSubpath()
        }
    }
}

private struct QuestCircuitry: View {
    var body: some View {
        Canvas { context, size in
            // Fine angular paths: a deterministic pattern so the glass never jumps on a redraw.
            for index in 0..<340 {
                let seed = index * 13
                let x = noise(seed) * size.width
                let y = noise(seed + 1) * size.height
                let length = 12 + noise(seed + 2) * 120
                let direction: CGFloat = index.isMultiple(of: 2) ? 1 : -1
                var circuit = Path()
                circuit.move(to: CGPoint(x: x, y: y))
                circuit.addLine(to: CGPoint(x: x + length * 0.42, y: y + length * 0.42 * direction))
                circuit.addLine(to: CGPoint(x: x + length * 0.42 + 7, y: y + length * 0.42 * direction))
                circuit.addLine(to: CGPoint(x: x + length * 0.66 + 7, y: y + length * 0.66 * direction))
                circuit.addLine(to: CGPoint(x: x + length * 0.66 + 14, y: y + length * 0.66 * direction))
                circuit.addLine(to: CGPoint(x: x + length + 14, y: y + length * direction))
                let opacity = 0.026 + noise(seed + 3) * 0.068
                context.stroke(circuit, with: .color(QuestLight.cyan.opacity(opacity)), lineWidth: index.isMultiple(of: 9) ? 0.85 : 0.4)
                if index.isMultiple(of: 3) {
                    let terminal = CGRect(x: x - 1.2, y: y - 1.2, width: 2.4, height: 2.4)
                    context.stroke(Path(terminal), with: .color(QuestLight.cyan.opacity(opacity * 1.4)), lineWidth: 0.4)
                }
            }
            // Interrupted, uneven filaments resemble interference rather than concentric rings.
            for bundle in 0..<18 {
                let center = CGPoint(x: noise(bundle * 9 + 71) * size.width,
                                     y: noise(bundle * 9 + 72) * size.height)
                for strand in 0..<7 {
                    var line = Path()
                    var continuing = false
                    for step in 0...70 {
                        let t = CGFloat(step) / 70
                        let angle = t * .pi * 1.5 + CGFloat(bundle)
                        let spread = CGFloat(strand) * (1.2 + sin(t * 9 + CGFloat(bundle)) * 0.8)
                        let radius = 24 + spread + sin(t * 13 + CGFloat(bundle)) * 12 + cos(t * 23) * 3
                        let x = center.x + cos(angle) * radius + sin(t * 9) * 24 + (t - 0.5) * 70
                        let y = center.y + sin(angle) * radius * 1.4 + (t - 0.5) * 135
                        if (step + bundle * 3 + strand) % 23 < 3 {
                            continuing = false
                        } else {
                            let point = CGPoint(x: x, y: y)
                            if continuing { line.addLine(to: point) } else { line.move(to: point) }
                            continuing = true
                        }
                    }
                    context.drawLayer { threads in
                        if strand.isMultiple(of: 3) { threads.addFilter(.blur(radius: 0.6)) }
                        threads.stroke(line, with: .color(QuestLight.cyan.opacity(0.055 + Double(strand % 3) * 0.019)), lineWidth: 0.45)
                    }
                }
            }
            for index in 0..<100 {
                let x = noise(index * 7 + 901) * size.width
                let y = noise(index * 7 + 902) * size.height
                let edge = x < 28 || x > size.width - 28
                context.fill(Path(CGRect(x: x, y: y, width: index % 4 == 0 ? 1.5 : 0.65, height: 0.7)),
                             with: .color(QuestLight.cyan.opacity(edge ? 0.6 : 0.17)))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func noise(_ seed: Int) -> CGFloat {
        let n = sin(Double(seed) * 127.1 + 311.7) * 43758.5453
        return CGFloat(n - floor(n))
    }
}

private struct QuestFrame: View {
    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height
            // Separate, stepped side rails expose small pockets of the scene between fragments.
            let leftSections: [(CGFloat, CGFloat, CGFloat)] = [(0.025, 0.17, 0), (0.197, 0.245, 5),
                (0.258, 0.475, 1), (0.510, 0.548, 7), (0.567, 0.773, 0), (0.811, 0.853, 6), (0.880, 0.975, 1)]
            let rightSections: [(CGFloat, CGFloat, CGFloat)] = [(0.025, 0.135, 1), (0.164, 0.227, 7),
                (0.245, 0.427, 0), (0.455, 0.488, 5), (0.516, 0.726, 1), (0.759, 0.816, 6), (0.846, 0.974, 0)]
            for side in 0..<2 {
                let sections = side == 0 ? leftSections : rightSections
                for (index, section) in sections.enumerated() {
                    let (start, end, offset) = section
                    let x: CGFloat = side == 0 ? 5 + offset : w - 5 - offset
                    let sign: CGFloat = side == 0 ? 1 : -1
                    let y1 = h * start
                    let y2 = h * end
                    var rail = Path()
                    rail.move(to: CGPoint(x: x, y: y1))
                    rail.addLine(to: CGPoint(x: x, y: y2 - 8))
                    rail.addLine(to: CGPoint(x: x + 5 * sign, y: y2 - 3))
                    rail.addLine(to: CGPoint(x: x + 5 * sign, y: y2))
                    context.drawLayer { glow in
                        glow.addFilter(.blur(radius: 3))
                        glow.stroke(rail, with: .color(QuestLight.blue.opacity(0.43)), lineWidth: 4)
                    }
                    context.stroke(rail, with: .color(QuestLight.blue.opacity(0.53)), lineWidth: 2.5)
                    context.stroke(rail, with: .color(QuestLight.ink.opacity(index.isMultiple(of: 3) ? 0.85 : 0.45)), lineWidth: 0.7)
                    let parallel = rail.applying(CGAffineTransform(translationX: sign * 3.5, y: 2))
                    context.stroke(parallel, with: .color(QuestLight.cyan.opacity(0.42)), lineWidth: 0.6)
                    let fine = rail.applying(CGAffineTransform(translationX: -sign * 3, y: CGFloat(index % 3 * 3)))
                    context.stroke(fine, with: .color(QuestLight.ink.opacity(0.3)), lineWidth: 0.5)

                    // Pale glass fragments vary in width and opacity; the gaps remain fully clear.
                    let width: CGFloat = index.isMultiple(of: 3) ? 4.5 : 2.4
                    let startY = y1 + CGFloat(3 + index % 3 * 5)
                    let endY = y2 - CGFloat(13 + index % 2 * 8)
                    var glass = Path()
                    glass.move(to: CGPoint(x: x + sign * 1.5, y: startY))
                    glass.addLine(to: CGPoint(x: x + sign * (width + 1.5), y: startY + 2))
                    glass.addLine(to: CGPoint(x: x + sign * (width + 1.5), y: endY - 6))
                    glass.addLine(to: CGPoint(x: x + sign * (width + 4), y: endY - 2))
                    glass.addLine(to: CGPoint(x: x + sign * 3.5, y: endY + 3))
                    glass.addLine(to: CGPoint(x: x + sign * 1.5, y: endY - 3))
                    glass.closeSubpath()
                    context.fill(glass, with: .color(QuestLight.ink.opacity(index.isMultiple(of: 3) ? 0.36 : 0.17)))
                    // Detached slivers and horizontal offsets make the edge look imperfectly projected.
                    let chipY = y2 + 3
                    for chip in 0..<3 {
                        let chipRect = CGRect(x: x - CGFloat(chip) * sign * 1.4, y: chipY + CGFloat(chip * 2),
                                              width: CGFloat(2 + (index + chip) % 5), height: 0.9)
                        context.fill(Path(chipRect), with: .color(QuestLight.cyan.opacity(0.3 + Double(chip) * 0.15)))
                    }
                }
            }
            // Layered blue top and bottom beams with bright, localized bloom.
            for bottom in [false, true] {
                let y: CGFloat = bottom ? h - 4 : 4
                let sign: CGFloat = bottom ? -1 : 1
                var beam = Path()
                beam.move(to: CGPoint(x: 1, y: y))
                beam.addLine(to: CGPoint(x: 51, y: y))
                beam.addLine(to: CGPoint(x: 64, y: y + sign * 5))
                beam.addLine(to: CGPoint(x: w - 20, y: y + sign * 5))
                beam.addLine(to: CGPoint(x: w - 2, y: y - sign * 2))
                context.drawLayer { glow in
                    glow.addFilter(.blur(radius: 5))
                    glow.stroke(beam, with: .color(QuestLight.blue.opacity(0.9)), lineWidth: 7)
                }
                context.stroke(beam, with: .color(QuestLight.blue.opacity(0.8)), lineWidth: 4)
                context.stroke(beam, with: .color(QuestLight.cyan.opacity(0.95)), lineWidth: 1.3)
                let parallel = beam.applying(CGAffineTransform(translationX: 0, y: sign * 3))
                context.stroke(parallel, with: .color(QuestLight.ink.opacity(0.7)), lineWidth: 0.6)
                // Electrical interference is concentrated in three small, uneven clusters.
                for cluster in 0..<3 {
                    let centerX = w * (bottom ? [0.16, 0.53, 0.85][cluster] : [0.27, 0.61, 0.81][cluster])
                    var sparks = Path()
                    for strand in 0..<7 {
                        for step in 0...35 {
                            let t = CGFloat(step) / 35
                            let offset = CGFloat((strand * 11 + cluster * 7) % 19 - 9)
                            let length = CGFloat(9 + (strand * 7 + cluster * 13) % 31)
                            let x = centerX + offset + (t - 0.5) * length
                            let wave = sin(t * CGFloat(5 + strand) + CGFloat(strand * 3)) * 3.4
                                + sin(t * 37 + CGFloat(strand * 7)) * 0.8
                            let point = CGPoint(x: x, y: y + wave * sin(t * .pi) + CGFloat(strand - 3) * 0.6)
                            if step == 0 { sparks.move(to: point) } else { sparks.addLine(to: point) }
                        }
                    }
                    context.drawLayer { glow in
                        glow.addFilter(.blur(radius: 3))
                        glow.stroke(sparks, with: .color(QuestLight.cyan.opacity(0.8)), lineWidth: 1.3)
                    }
                    context.stroke(sparks, with: .color(QuestLight.cyan.opacity(0.75)), lineWidth: 0.45)
                }
                for index in 0..<21 {
                    let x = CGFloat(index) * (w - 30) / 21 + 12
                    let length = CGFloat((index * 7) % 15 + 2)
                    let fragment = CGRect(x: x, y: y + CGFloat(index % 3) * sign * 2 - 1, width: length, height: index % 5 == 0 ? 2 : 0.7)
                    context.fill(Path(fragment), with: .color(QuestLight.ink.opacity(index % 4 == 0 ? 0.75 : 0.28)))
                }
            }
            // Almost-white inner hairline, with small duplicated and displaced fragments.
            let inner = CGRect(x: 21, y: 22, width: w - 42, height: h - 44)
            context.stroke(Path(inner), with: .color(QuestLight.ink.opacity(0.40)), lineWidth: 0.55)
            for index in 0..<26 {
                let left = index.isMultiple(of: 2)
                let x = left ? inner.minX : inner.maxX
                let y = inner.minY + CGFloat(index) / 26 * inner.height
                let line = CGRect(x: x + (index % 3 == 0 ? 1.2 : -0.6), y: y, width: 0.7, height: CGFloat(4 + index % 5 * 3))
                context.fill(Path(line), with: .color(QuestLight.ink.opacity(index % 3 == 0 ? 0.75 : 0.35)))
            }
            for index in 0..<18 {
                let x = inner.minX + CGFloat(index) / 18 * inner.width
                let y = index.isMultiple(of: 2) ? inner.minY : inner.maxY
                context.fill(Path(CGRect(x: x, y: y - 1, width: CGFloat(3 + index % 4 * 4), height: 0.7)),
                             with: .color(QuestLight.ink.opacity(0.56)))
            }
        }
    }
}

#Preview {
    SystemView()
        .environmentObject(GameStore(persistence: .memory))
}
