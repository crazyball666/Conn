# Terminal Theme Catalog Design

**Date:** 2026-08-16  
**Status:** Confirmed  
**Scope:** Built-in terminal palettes, theme and cursor previews, and terminal-screen appearance

## 1. Goal

Make terminal themes visibly distinguishable and add a complete light-theme choice without breaking persisted theme IDs or changing the default Conn dark theme.

## 2. Current Problems

- All eight built-in themes are dark.
- Several dark themes have nearly identical backgrounds: Dracula `#282A36`, One Dark `#282C34`, and Gruvbox Dark `#282828`; Tokyo Night and Catppuccin Mocha are also close.
- The settings picker renders only three tiny circles for background, cursor, and foreground. It hides the ANSI palette differences that make these themes distinct.
- `TerminalScreen` forces a dark color scheme, so adding only a light terminal canvas would leave the navigation bar, keybar, and software keyboard visually mismatched.

## 3. Product Behavior

### 3.1 Catalog

- Keep all current theme IDs and palettes so saved preferences remain valid.
- Add an explicit `light` or `dark` appearance to every theme.
- Add five light themes with distinct visual families:
  - Conn Light: neutral branded light canvas with violet cursor/accent.
  - Solarized Light: low-glare cream and teal palette.
  - Gruvbox Light: warm retro cream palette.
  - One Light: neutral editor-style white palette.
  - Catppuccin Latte: cool pastel light palette.
- Keep Conn dark as the default.

### 3.2 Picker

- Group themes under existing localized labels “深色” and “浅色”.
- Replace the three-dot marker with a real compact preview:
  - a rounded background swatch containing foreground “Aa” and a cursor mark;
  - a compact strip of representative ANSI colors;
  - the theme name.
- The preview must remain readable in the picker without changing the stored value shape.

### 3.3 Terminal Presentation

- A dark terminal theme uses dark system chrome and keyboard appearance.
- A light terminal theme uses light system chrome and keyboard appearance.
- Terminal viewport background, foreground, cursor, and ANSI palette continue to come from the selected `TerminalTheme`.
- The keybar uses existing dynamic ConnUI color assets and follows the terminal screen color scheme.

### 3.4 Cursor Preview

- Replace the text-only segmented cursor picker with three compact selectable cards.
- Each card renders a terminal glyph and the actual cursor geometry for block, vertical bar, or underline, plus its localized label.
- The selected card uses the app accent border/fill and remains a minimum 44-point touch target.
- Cursor blinking remains an independent toggle; the settings preview is static so comparison does not create distracting animation.
- The preview uses the currently selected terminal theme foreground, background, and cursor colors so the user sees the real combination before opening a terminal.

## 4. Architecture

`TerminalTheme` gains a nested, Sendable `Appearance` enum and an `appearance` value. Existing themes explicitly declare `.dark`; new themes declare `.light`. Catalog lookup remains ID-based, so no database or UserDefaults migration is needed.

`TerminalSettingsView` filters the single catalog by appearance and owns picker presentation. Theme and cursor previews are private SwiftUI components/functions and do not introduce a second palette or cursor model. The cursor cards bind directly to the existing `TerminalCursorShape` setting.

`TerminalScreen` maps the active configured theme appearance to SwiftUI `ColorScheme` and applies it to both `preferredColorScheme` and navigation-bar toolbar color scheme. ConnTerminal remains UI-framework-neutral at the domain boundary.

## 5. Validation

Automated tests must verify:

1. every theme has exactly 16 ANSI colors and a unique ID;
2. complete palette signatures are unique;
3. the catalog contains five light themes and all existing dark IDs;
4. foreground/background contrast is at least 4.5:1;
5. unknown persisted IDs still fall back to Conn dark;
6. the settings picker groups both appearances and renders background, text/cursor, and ANSI preview elements;
7. `TerminalScreen` derives color scheme from theme appearance and no longer hardcodes dark mode.
8. cursor settings render three selectable previews, bind to all existing cursor cases, and retain the separate blinking toggle.

Run the complete ConnPackages test suite, compile app tests for a generic iOS destination, and run `git diff --check`. Simulator UI acceptance may use only the simulator already booted by the user; if CoreSimulatorService is unavailable, do not create or switch devices.

## 6. Non-goals

- Downloadable or user-authored themes.
- Automatic theme switching based on time of day.
- Migrating or deleting existing dark themes solely because their backgrounds are similar.
- Changing the global app appearance preference outside `TerminalScreen`.
