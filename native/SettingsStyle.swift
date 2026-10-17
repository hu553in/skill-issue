import SwiftUI

enum SettingsLayout {
    static let compactSpacing: CGFloat = 8
    static let spacing: CGFloat = 12
    static let sectionSpacing: CGFloat = 20
    static let windowPadding: CGFloat = 26
    static let sheetWidth: CGFloat = 468
    static let textInset: CGFloat = 5
}

extension View {
    func settingsFieldBackground() -> some View {
        background(
            Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        }
    }
}
