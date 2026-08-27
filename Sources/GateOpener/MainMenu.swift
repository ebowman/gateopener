import AppKit

/// Builds and installs `NSApp.mainMenu`.
///
/// Root cause of the paste bug (bead gateopener-iif.1): in an
/// `LSUIElement`/`.accessory` app, AppKit does NOT install the standard
/// menus for you. With no main menu, there is no Edit menu, so the standard
/// editing key equivalents (Cmd-V, Cmd-C, Cmd-X, Cmd-A, Cmd-Z) are unbound
/// in EVERY `NSTextField` in the app — not just the password field.
///
/// This assigns a hand-built `NSMenu` (rather than SwiftUI's
/// `Commands`/`CommandGroup`) because `GateOpenerMain` is a plain
/// `NSApplicationDelegate`-driven AppKit app, not a SwiftUI `App` scene —
/// there is no `Commands` builder available to hook into.
///
/// Edit menu items are wired to the standard first-responder selectors
/// (`cut:`, `copy:`, `paste:`, etc.) with `target: nil` so AppKit's
/// responder chain resolves them at the currently-focused text field —
/// deliberately NOT custom handlers, so behaviour matches every other
/// Mac app exactly.
enum MainMenu {
    /// Builds the menu bar and assigns it to `NSApp.mainMenu`.
    ///
    /// Must be called from `applicationDidFinishLaunching` BEFORE any
    /// window is shown (the Settings window can auto-open on
    /// `.needsSetup`), so the responder chain has a main menu to route
    /// through the first time a text field becomes first responder.
    ///
    /// Assigning `NSApp.mainMenu` does not affect activation policy — it
    /// does not cause a Dock icon to appear, and does not change
    /// `.accessory` behaviour. That's controlled solely by
    /// `NSApp.setActivationPolicy(_:)` in `GateOpenerMain.main()`.
    @MainActor
    static func install() {
        let mainMenu = NSMenu()

        mainMenu.addItem(makeAppMenuItem())
        mainMenu.addItem(makeEditMenuItem())

        NSApp.mainMenu = mainMenu
    }

    /// The application menu (conventionally the first item, titled with
    /// the app name at render time by AppKit). Contains at least Quit
    /// (Cmd-Q), wired to `NSApplication.terminate(_:)`.
    ///
    /// This is independent of the existing Quit item in the status-item
    /// right-click menu (`StatusItemController.showMenu()`): that item's
    /// `keyEquivalent: "q"` only fires while that popped-up `NSMenu` is
    /// open, so it never competes with this main-menu Cmd-Q for the key
    /// equivalent. Both ultimately call `NSApp.terminate(nil)`, so
    /// whichever the operator uses, the app quits exactly once.
    @MainActor
    private static func makeAppMenuItem() -> NSMenuItem {
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()

        let quitItem = NSMenuItem(
            title: "Quit GateOpener",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = nil
        appMenu.addItem(quitItem)

        appMenuItem.submenu = appMenu
        return appMenuItem
    }

    /// The Edit menu. Every item routes through the responder chain
    /// (`target: nil`) to the standard `NSText`/`NSResponder` editing
    /// selectors, so AppKit itself resolves them against whatever text
    /// field currently has focus.
    @MainActor
    private static func makeEditMenuItem() -> NSMenuItem {
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")

        editMenu.addItem(makeItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(makeItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z", modifiers: [.command, .shift]))
        editMenu.addItem(.separator())
        editMenu.addItem(makeItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(makeItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(makeItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(.separator())
        editMenu.addItem(makeItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))

        editMenuItem.submenu = editMenu
        return editMenuItem
    }

    @MainActor
    private static func makeItem(
        title: String,
        action: Selector,
        keyEquivalent: String,
        modifiers: NSEvent.ModifierFlags = [.command]
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = nil
        item.keyEquivalentModifierMask = modifiers
        return item
    }
}
