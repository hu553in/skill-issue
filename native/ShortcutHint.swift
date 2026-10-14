import SwiftUI

enum ShortcutKey {
    case space, up, down, left, right, minus, plus, menuBarIcon

    var name: String {
        switch self {
        case .space: "Space"
        case .up: "Up arrow"
        case .down: "Down arrow"
        case .left: "Left arrow"
        case .right: "Right arrow"
        case .minus: "Minus"
        case .plus: "Plus"
        case .menuBarIcon: "H"
        }
    }
    var symbol: String? {
        switch self {
        case .space: "space"
        case .up: "arrow.up"
        case .down: "arrow.down"
        case .left: "arrow.left"
        case .right: "arrow.right"
        case .minus: "minus"
        case .plus: "plus"
        case .menuBarIcon: nil
        }
    }
    func hint(_ modifiers: ShortcutModifiers) -> String { "\(modifiers.names) + \(name)" }
}

struct ShortcutModifierSymbols: View {
    let modifiers: ShortcutModifiers

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            ForEach(ShortcutModifiers.ordered, id: \.name) {
                if modifiers.contains($0.modifier) { Image(systemName: $0.image) }
            }
        }
        .imageScale(.small)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(modifiers.names)
    }
}

struct ShortcutHint: View {
    let key: ShortcutKey
    var modifiers: ShortcutModifiers?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            if let modifiers { ShortcutModifierSymbols(modifiers: modifiers) }
            if let symbol = key.symbol {
                Image(systemName: symbol)
            } else {
                Text(key.name)
            }
        }
        .font(.callout)
    }
}
