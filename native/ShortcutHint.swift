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
    var hint: String { "Control + Option + Command + \(name)" }
}

struct ShortcutModifiers: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Image(systemName: "control")
            Image(systemName: "option")
            Image(systemName: "command")
        }
        .imageScale(.small)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Control + Option + Command")
    }
}

struct ShortcutHint: View {
    let key: ShortcutKey
    var includeModifiers = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            if includeModifiers { ShortcutModifiers() }
            if let symbol = key.symbol {
                Image(systemName: symbol)
            } else {
                Text(key.name)
            }
        }
        .font(.callout)
    }
}
