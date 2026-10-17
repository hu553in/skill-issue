import AppKit

@MainActor
func applicationMenu() -> NSMenu {
    let menu = NSMenu()
    let application = NSMenu(title: "Skill Issue")
    application.addItem(
        withTitle: "Quit Skill Issue", action: #selector(NSApplication.terminate(_:)),
        keyEquivalent: "q")
    let applicationItem = NSMenuItem()
    applicationItem.submenu = application
    menu.addItem(applicationItem)

    let file = NSMenu(title: "File")
    file.addItem(
        withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    let fileItem = NSMenuItem()
    fileItem.submenu = file
    menu.addItem(fileItem)

    let edit = NSMenu(title: "Edit")
    edit.addItem(withTitle: "Undo", action: NSSelectorFromString("undo:"), keyEquivalent: "z")
    let redo = edit.addItem(
        withTitle: "Redo", action: NSSelectorFromString("redo:"), keyEquivalent: "z")
    redo.keyEquivalentModifierMask = [.command, .shift]
    edit.addItem(.separator())
    edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    edit.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
    edit.addItem(.separator())
    edit.addItem(
        withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    let editItem = NSMenuItem()
    editItem.submenu = edit
    menu.addItem(editItem)
    return menu
}
