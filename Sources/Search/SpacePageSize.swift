import SwiftUI

// A space's page size: its pages laid out in a box of a chosen size in the
// middle of the window, for looking at sites as a narrow screen has them.
//
// It is the size and nothing more: the page's viewport is as wide and as tall
// as the box, while it is still the same browser to the site, with this Mac's
// user agent, pixel density and pointer. A window too small for the box gives
// it what there is. A split, or a video filling the window, takes the whole
// of it as ever.

enum PageSize: String, CaseIterable, Identifiable {
    case smallPhone, phone, tablet, laptop

    var id: String { rawValue }

    var size: CGSize {
        switch self {
        case .smallPhone: CGSize(width: 375, height: 667)
        case .phone: CGSize(width: 393, height: 852)
        case .tablet: CGSize(width: 820, height: 1180)
        case .laptop: CGSize(width: 1280, height: 800)
        }
    }

    var title: String {
        let name = switch self {
        case .smallPhone: "Small phone"
        case .phone: "Phone"
        case .tablet: "Tablet"
        case .laptop: "Laptop"
        }
        return "\(name), \(Int(size.width)) × \(Int(size.height))"
    }
}

extension Browser {
    /// The box the page in front is laid out in, or nil for the whole stage.
    var pageSize: PageSize? {
        guard prefs.usesSpaces, activeSplit == nil else { return nil }
        return spaces.first { $0.id == spaceID }?.pageSize.flatMap(PageSize.init)
    }

    func setPageSize(_ id: UUID, to size: PageSize?) {
        guard let at = spaces.firstIndex(where: { $0.id == id }) else { return }
        spaces[at].pageSize = size?.rawValue
        Spaces.write(spaces, profile: profileID)
    }
}

/// Always there, so choosing a size never rebuilds the stage: with none, both
/// frames are the room it already had.
struct PageSizeFrame: ViewModifier {
    let size: CGSize?

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: size?.width ?? .infinity, maxHeight: size?.height ?? .infinity)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Settings › Spaces & Pins › Page Size.
struct SpacePageSizes: View {
    @ObservedObject var browser: Browser

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(browser.spaces) { space in
                Line(space.name, "How big its pages are laid out. The size only: sites still see a Mac.") {
                    Picker("Page size", selection: Binding(
                        get: { space.pageSize.flatMap(PageSize.init) },
                        set: { browser.setPageSize(space.id, to: $0) }
                    )) {
                        Text("Fill the window").tag(PageSize?.none)
                        ForEach(PageSize.allCases) { Text(verbatim: $0.title).tag(PageSize?.some($0)) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 200)
                }
            }
        }
    }
}
