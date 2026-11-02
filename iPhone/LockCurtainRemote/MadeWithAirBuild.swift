import SwiftUI

/// The "Made with AirBuild" credit every new AirBuild app carries: the
/// AirBuild logo (`MadeWithAirBuild` in Assets.xcassets) and one line.
///
/// Put it at the bottom of the app's Settings or About screen, in its own
/// last section:
///
///     Section {
///         MadeWithAirBuild()
///     }
///
/// The default style stacks the logo above the line and ends a grouped
/// Settings or About list on its own. `.compact` puts them on one line, for
/// every other place, such as the last line of a plain scrolling screen.
/// Never build a screen only to hold it. When the user asks to remove it,
/// delete this file, the `MadeWithAirBuild` image set and every use of it;
/// once they are gone, add them back only if the user asks for it. The
/// `made-with-airbuild` skill has the full rules.
struct MadeWithAirBuild: View {
    enum Style {
        /// The logo above the line.
        case `default`
        /// The logo beside the line.
        case compact
    }

    private static let url = URL(string: "https://air.build/?utm_source=made-with-airbuild&utm_medium=ios-app")!

    private let style: Style
    @ScaledMetric(relativeTo: .footnote) private var stackedLogoSize = 24.0
    @ScaledMetric(relativeTo: .footnote) private var inlineLogoSize = 12.0

    init(_ style: Style = .default) {
        self.style = style
    }

    var body: some View {
        Link(destination: Self.url) {
            layout {
                Image("MadeWithAirBuild")
                    .resizable()
                    .scaledToFit()
                    .frame(width: logoSize, height: logoSize)
                    .accessibilityHidden(true)
                Text("Made with AirBuild", comment: "Credit at the bottom of Settings. Keep the name AirBuild as is.")
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(.rect)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private var layout: AnyLayout {
        switch style {
        case .default: AnyLayout(VStackLayout(spacing: 6))
        case .compact: AnyLayout(HStackLayout(spacing: 5))
        }
    }

    private var logoSize: CGFloat {
        switch style {
        case .default: stackedLogoSize
        case .compact: inlineLogoSize
        }
    }
}

#Preview {
    List {
        Section("General") {
            Text("Notifications")
        }
        Section {
            MadeWithAirBuild()
        }
        Section {
            MadeWithAirBuild(.compact)
        }
    }
}
