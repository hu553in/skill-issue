import SwiftUI

struct SettingsLink: View {
    let title: LocalizedStringKey
    let destination: URL
    @State private var hovered = false

    var body: some View {
        Link(destination: destination) {
            Text(title)
                .overlay(alignment: .bottom) {
                    Rectangle().frame(height: 1).offset(y: 1)
                        .opacity(hovered ? 1 : 0)
                        .allowsHitTesting(false)
                }
                .foregroundStyle(Color(nsColor: SettingsColors.link))
        }
        .font(.callout)
        .frame(minHeight: 24, alignment: .leading)
        .pointerStyle(.link)
        .onHover { hovered = $0 }
    }
}
