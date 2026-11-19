#if DEBUG && os(iOS)
import SwiftUI
import UIKit

/// Every widget design at its real size, numbered, for choosing which to keep.
/// Launch with WIDGET_GALLERY=1: the pages are saved as PNGs in the app's Documents folder.
@MainActor
enum WidgetGallery {
    struct Item: Identifiable {
        let number: Int
        let design: WidgetDesign
        let size: WidgetSize
        var data: WidgetData = .sample
        var note: String? = nil
        var id: Int { number }
    }

    /// Every Systems row blue today, for the Red Systems empty state.
    static var allBlue: WidgetData {
        var data = WidgetData.sample
        data.systems = data.systems.map { var row = $0; row.today = .done; return row }
        return data
    }

    static let pageOne: [Item] = [
        Item(number: 1, design: .nextQuest, size: .small),
        Item(number: 2, design: .redSystems, size: .small),
        Item(number: 3, design: .redSystems, size: .medium),
        Item(number: 4, design: .systemsGrid, size: .medium),
    ]

    static let pageTwo: [Item] = [
        Item(number: 5, design: .redSystems, size: .large),
        Item(number: 6, design: .systemsGrid, size: .large),
    ]

    static let pageThree: [Item] = [
        Item(number: 2, design: .redSystems, size: .small, data: allBlue, note: "all blue"),
        Item(number: 3, design: .redSystems, size: .medium, data: allBlue, note: "all blue"),
    ]

    static func frame(_ size: WidgetSize) -> CGSize {
        switch size {
        case .small: CGSize(width: 170, height: 170)
        case .medium: CGSize(width: 364, height: 170)
        case .large: CGSize(width: 364, height: 382)
        }
    }

    struct Tile: View {
        let item: Item
        var body: some View {
            let size = WidgetGallery.frame(item.size)
            VStack(alignment: .leading, spacing: 6) {
                item.design.view(item.data, size: item.size)
                    .padding(16)
                    .frame(width: size.width, height: size.height)
                    .background(WidgetPalette.background)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 1)
                    }
                Text("\(item.number). \(item.design.name)" + (item.note.map { " (\($0))" } ?? ""))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .frame(width: max(size.width, 170), alignment: .leading)
            }
        }
    }

    struct Page: View {
        let title: String
        let items: [Item]
        var body: some View {
            VStack(alignment: .leading, spacing: 18) {
                Text(title)
                    .font(.system(size: 13, weight: .heavy))
                    .tracking(2)
                    .foregroundStyle(.white)
                let smalls = items.filter { $0.size == .small }
                let rows = stride(from: 0, to: smalls.count, by: 2).map { Array(smalls[$0..<min($0 + 2, smalls.count)]) }
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .top, spacing: 24) {
                        ForEach(row) { Tile(item: $0) }
                    }
                }
                ForEach(items.filter { $0.size != .small }) { Tile(item: $0) }
            }
            .padding(19)
            .frame(width: 402, alignment: .topLeading)
            .background(LinearGradient(colors: [Color(red: 0.16, green: 0.18, blue: 0.24), Color(red: 0.06, green: 0.07, blue: 0.10)],
                                       startPoint: .top, endPoint: .bottom))
        }
    }

    /// Saves the three pages as PNGs in Documents.
    static func export() {
        guard let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let pages = [Page(title: "SMALL AND MEDIUM", items: pageOne),
                     Page(title: "LARGE", items: pageTwo),
                     Page(title: "RED SYSTEMS WHEN ALL ARE BLUE", items: pageThree)]
        for (index, page) in pages.enumerated() {
            let renderer = ImageRenderer(content: page.environment(\.colorScheme, .dark))
            renderer.scale = 3
            if let data = renderer.uiImage?.pngData() {
                try? data.write(to: folder.appendingPathComponent("widget-gallery-\(index + 1).png"))
            }
        }
    }
}
#endif
