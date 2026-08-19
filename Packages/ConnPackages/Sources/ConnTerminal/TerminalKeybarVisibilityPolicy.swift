enum TerminalKeybarVisibilityPolicy {
    static func shouldShow(
        configurationShowsKeybar: Bool,
        terminalFocused: Bool,
        reviewActive: Bool,
        userPinned: Bool,
        providerActionPresented: Bool
    ) -> Bool {
        configurationShowsKeybar
            && (terminalFocused || reviewActive || userPinned || providerActionPresented)
    }
}
