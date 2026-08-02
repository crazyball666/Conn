# Interactive CPU Chart Design

## Goal

Make the host-detail CPU chart useful for comparing all eight CPU time categories while keeping the dense mobile layout readable. The metric grid above the chart acts as the interactive legend.

## Scope

- CPU chart and the eight CPU metric items in the host overview.
- Disk read/write chart colors.
- No changes to collection intervals, SSH commands, persistence, or database schema.

## CPU Metrics

The chart supports these eight existing values, in the same order as the metric grid:

1. User
2. System
3. IO wait
4. Idle
5. Nice
6. Hardware interrupt
7. Software interrupt
8. Steal

Each metric keeps an independent rolling history in `HostOverviewViewModel`. All eight metrics are visible by default whenever the view is created.

## Interaction

- The whole metric cell, not only its text or dot, is tappable.
- Every cell has a minimum 44-point touch height and uses a plain button style.
- Tapping a visible metric hides its line; tapping it again restores the line.
- A visible metric uses its fixed semantic color. A hidden metric uses the standard muted gray for its dot, label, and value.
- Each toggle produces one selection haptic through SwiftUI sensory feedback.
- Hiding all metrics is allowed. The chart area then shows a centered prompt asking the user to select a metric.
- Accessibility labels include the metric name and its visible/hidden state; the hint explains that activating the item toggles its chart line.

The selection is view-local and is intentionally not persisted. Returning to a newly created host-detail view resets all metrics to visible.

## Chart Rendering

- The CPU chart receives only the currently visible metric series.
- CPU series always render as lines, even when only one metric remains visible; no area fill is used because it would imply a different chart mode after a toggle.
- The chart retains the 0–100% Y domain and the current rolling time window.
- Line order follows the metric-grid order so overlap remains deterministic.
- The numeric grid remains visible even when a metric line is hidden; hiding affects chart visibility only.

## Fixed Palette

CPU colors are fixed and independent of the app theme:

| Metric | Color |
| --- | --- |
| User | Blue `#2563EB` |
| System | Red `#DC2626` |
| IO wait | Amber `#CA8A04` |
| Idle | Slate `#7C8494` |
| Nice | Green `#16A34A` |
| Hardware interrupt | Purple `#9333EA` |
| Software interrupt | Magenta `#DB2777` |
| Steal | Teal `#0D9488` |

This makes User and System immediately distinguishable and avoids assigning two adjacent CPU metrics nearly identical colors.

The disk chart also uses fixed high-contrast colors:

- Read: blue `#2563EB`
- Write: orange-red `#EA580C`

The legend dots and chart lines always use the same colors.

## Data and State

`HostOverviewViewModel` records separate history arrays for all eight CPU categories. The previous combined `other` history is no longer used by the chart. A small value-type selection model owns the visible metric set so default visibility and toggle behavior can be tested without rendering SwiftUI.

## Verification

- Unit test: all eight CPU metrics are visible by default.
- Unit test: toggling a metric hides it and toggling again restores it without affecting other metrics.
- Unit test: CPU sampling records all eight category histories independently.
- Existing monitor parser tests continue to verify CPU category values.
- Build and run on the already-booted iPhone 17 Pro simulator.
- Visual check: eight distinct lines, gray hidden cells, empty-selection prompt, and clearly separated disk read/write colors.
