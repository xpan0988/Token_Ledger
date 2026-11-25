import KeyboardShortcuts

@MainActor
extension KeyboardShortcuts.Name {
    static let openMenu = Self("openMenu")
    static let toggleTokenLedger = Self(
        "toggleTokenLedger",
        initial: .init(.l, modifiers: [.control, .option, .command]))
}
