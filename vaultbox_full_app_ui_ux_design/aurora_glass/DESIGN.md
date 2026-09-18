---
name: Aurora Glass
colors:
  surface: '#fbf9f4'
  surface-dim: '#dcdad5'
  surface-bright: '#fbf9f4'
  surface-container-lowest: '#ffffff'
  surface-container-low: '#f5f3ee'
  surface-container: '#f0eee9'
  surface-container-high: '#eae8e3'
  surface-container-highest: '#e4e2dd'
  on-surface: '#1b1c19'
  on-surface-variant: '#484551'
  inverse-surface: '#30312d'
  inverse-on-surface: '#f3f1eb'
  outline: '#797582'
  outline-variant: '#c9c4d2'
  surface-tint: '#5f53a4'
  primary: '#5c50a1'
  on-primary: '#ffffff'
  primary-container: '#7569bc'
  on-primary-container: '#fffbff'
  inverse-primary: '#c8bfff'
  secondary: '#005eb4'
  on-secondary: '#ffffff'
  secondary-container: '#5a9fff'
  on-secondary-container: '#00356a'
  tertiary: '#864866'
  on-tertiary: '#ffffff'
  tertiary-container: '#a2607f'
  on-tertiary-container: '#fffbff'
  error: '#ba1a1a'
  on-error: '#ffffff'
  error-container: '#ffdad6'
  on-error-container: '#93000a'
  primary-fixed: '#e5deff'
  primary-fixed-dim: '#c8bfff'
  on-primary-fixed: '#1a045e'
  on-primary-fixed-variant: '#473a8a'
  secondary-fixed: '#d5e3ff'
  secondary-fixed-dim: '#a8c8ff'
  on-secondary-fixed: '#001b3c'
  on-secondary-fixed-variant: '#00468a'
  tertiary-fixed: '#ffd8e7'
  tertiary-fixed-dim: '#feb0d2'
  on-tertiary-fixed: '#390724'
  on-tertiary-fixed-variant: '#6d3350'
  background: '#fbf9f4'
  on-background: '#1b1c19'
  surface-variant: '#e4e2dd'
  surface-primary: '#FFFFFF'
  surface-secondary: '#FAFAFA'
  surface-tertiary: '#F7F7F5'
  ink-primary: '#1A1A1A'
  ink-secondary: '#666666'
  ink-tertiary: '#8A8A8A'
  ink-disabled: '#A5A5A5'
  border-strong: '#1A1A1A'
  border-default: '#DCDCDC'
  border-muted: '#E8E8E8'
  selection-blue: '#2A78D6'
  selection-soft: '#EEF3FB'
  aurora-lavender: '#8F83D8'
  aurora-mid: '#B58FD0'
  aurora-pink: '#D98FB0'
  aurora-soft-l: '#CFC8EF'
  aurora-soft-p: '#EEC9D6'
  status-success: '#3A7A4A'
  status-success-border: '#B0CDB4'
  status-warning: '#8A6A2A'
  status-warning-border: '#DCD0B0'
  status-danger: '#A34A4A'
  status-danger-border: '#C98A8A'
  status-danger-surface: '#FDF6F6'
typography:
  display-xl:
    fontFamily: Epilogue
    fontSize: 36px
    fontWeight: '700'
    lineHeight: 44px
    letterSpacing: -0.02em
  display-xl-mobile:
    fontFamily: Epilogue
    fontSize: 30px
    fontWeight: '700'
    lineHeight: 38px
    letterSpacing: -0.02em
  headline-lg:
    fontFamily: Epilogue
    fontSize: 28px
    fontWeight: '600'
    lineHeight: 36px
    letterSpacing: -0.01em
  headline-md:
    fontFamily: Epilogue
    fontSize: 22px
    fontWeight: '600'
    lineHeight: 30px
  headline-sm:
    fontFamily: Epilogue
    fontSize: 18px
    fontWeight: '600'
    lineHeight: 24px
  body-lg:
    fontFamily: Inter
    fontSize: 16px
    fontWeight: '400'
    lineHeight: 24px
  body-md:
    fontFamily: Inter
    fontSize: 14px
    fontWeight: '400'
    lineHeight: 20px
  body-sm:
    fontFamily: Inter
    fontSize: 12px
    fontWeight: '400'
    lineHeight: 18px
  label-lg:
    fontFamily: Inter
    fontSize: 14px
    fontWeight: '500'
    lineHeight: 20px
  label-md:
    fontFamily: JetBrains Mono
    fontSize: 12px
    fontWeight: '500'
    lineHeight: 16px
  label-sm:
    fontFamily: JetBrains Mono
    fontSize: 10px
    fontWeight: '500'
    lineHeight: 14px
    letterSpacing: 0.02em
rounded:
  sm: 0.25rem
  DEFAULT: 0.5rem
  md: 0.75rem
  lg: 1rem
  xl: 1.5rem
  full: 9999px
spacing:
  gutter: 1rem
  gutter-sm: 0.75rem
  gutter-lg: 1.5rem
  margin: 1rem
  margin-sm: 0.875rem
  margin-lg: 1.5rem
  space-xs: 0.25rem
  space-sm: 0.5rem
  space-md: 1rem
  space-lg: 1.25rem
  space-xl: 1.5rem
---

## Brand & Style

This design system defines an artisanal, approachable, yet server-grade operating aesthetic for personal storage and self-hosted server nodes on Android. The product personality bridges two traditionally conflicting paradigms: the warm, handwritten intimacy of an artisanal notebook and the uncompromising precision of low-level networking tools. It eliminates the cold, clinical, and intimidating aura typical of network-attached storage or server consoles, replacing it with an inviting, transparent experience that makes local data sovereignty feel playful, dependable, and physically tangible.

The visual style blends crisp structural linework with selective **Glassmorphism** and soft cosmic luminescence:
- **Crisp Ink Structure**: Rather than relying on muddy drop shadows or heavy industrial cards, focal clarity is enforced by 1.5px ink-styled boundaries reminiscent of fountain pen linework and clear architectural blueprints.
- **Aurora Atmospheric Luminescence**: Tactile interactive touchpoints and focal server actions harness a glowing, shifting three-stop aurora gradient (lavender through lilac to rose).
- **Glass Refraction**: Translucent lens materials (70% to 88% opacity with subtle back-blur) are used surgically for floating controllers, navigation handles, and pairing targets to create depth without visual noise.
- **Dual-Tonal Typography**: The intentional friction between hand-drawn display headings and pixel-perfect technical monospace ensures the interface feels both human and surgically capable.

## Colors

The palette is anchored by a warm paper-like mineral neutral canvas (`#F0EEE9`) paired with clean functional white and off-white container tiers. Contrast is generated through a high-fidelity ink hierarchy rather than pure gray washes, maintaining legibility in harsh outdoor light and dense Android display environments.

### Brand Gradients & Accents
- **Primary Aurora**: `#8F83D8 → #B58FD0 → #D98FB0` (135° diagonal). Applied to active hero server indicators, primary interactive buttons, selection pills, and storage linear meters.
- **Soft Aurora**: `#CFC8EF → #EEC9D6` (135° diagonal). Used for luminous backdrop glows, onboarding spotlights, and empty-state ambient bubbles.
- **Interactive Blue**: `#2A78D6` with its soft counterpart `#EEF3FB` manages low-level file selections, multiselect marquees, and system links to clearly distinguish file selection actions from server-level brand actions.

### Semantic Status Enforcements
To guarantee accessibility and technical clarity, semantic indicators must pair chromatic values with symbolic glyphs:
- **Success (`#3A7A4A`)**: Accompanied by a solid glyph (`● Server Live`). Border: `#B0CDB4`.
- **Warning (`#8A6A2A`)**: Accompanied by an alert glyph (`! Limited` / `! Port Blocked`). Border: `#DCD0B0`.
- **Danger (`#A34A4A`)**: Accompanied by a terminal glyph (`× Offline` / `× Failed`). Border: `#C98A8A`, Fill: `#FDF6F6`.

## Typography

The typographic system orchestrates three distinct roles:
1. **Expressive Display Hierarchy**: Driven by the distinct, sculptural character of Epilogue (with Patrick Hand as a stylistic alternative on mobile personal notes and hero cards) to inject warmth, humanity, and narrative scale into an otherwise technical domain.
2. **Workhorse Reading & UI Utility**: Handled by Inter for neutral, highly legible file directories, folder paths, context menus, and configuration forms.
3. **Hardware & Network Telemetry**: Handled by JetBrains Mono. IP addresses (`192.168.1.142:8080`), cryptographic file hashes (`SHA-256`), port numbers, transfer throughputs (`48.2 MB/s`), and byte totals are set in monospaced glyphs to preserve tabular vertical alignment during real-time streaming updates.

### Responsive Scaling
All headline levels scale down automatically on devices narrower than 600dp to avoid unnatural line-wrapping on compact Android screens. Numeric indicators and telemetry readouts must always use tabular figures (`font-variant-numeric: tabular-nums`) to prevent text jitter during transfer rate fluctuations.

## Layout & Spacing

Layout geometry is built upon an incremental **4dp base grid system**. Empty space functions as a structural divider, keeping high-density telemetry readable.

### Grid & Breakpoints
- **Compact (< 600dp / Phone)**: Single-column canvas, 14–16dp screen edge margins, 12dp card padding. Primary navigation shifts exclusively to the floating bottom dock with a persistent 88dp clearance bottom margin to prevent floating controls from occluding scrollable file rows.
- **Medium (600–839dp / Foldables & Tablets)**: 2-column or dual-pane master-detail layout (file browser alongside realtime server telemetry monitor), 20dp edge margins, 16dp component gap.
- **Expanded (≥ 840dp / Desktop & DeX)**: Multi-column canvas with a permanent 72dp vertical navigation rail replacing the bottom dock, 24–32dp edge margins, fixed max-width content container of 1280dp.

### Layout Rules
- **Interactive Targets**: All clickable items enforce a strict minimum footprint of 48×48dp, even when visual chips are compact (e.g., small status badges padded out using hit-slop offsets).
- **Dock Offsets**: Content lists must append dynamic bottom scroll padding equal to the floating dock's height (74dp) plus its vertical margin (16dp) plus an extra safe-area buffer of 16dp.

## Elevation & Depth

Visual hierarchy rejects exaggerated, dark drop shadows in favor of precise structural boundaries, translucent refraction, and surface-contrast layering.

### Depth Hierarchy
1. **Base Tier (Ground Canvas)**: `#F0EEE9`. Completely flat and non-elevated. Forms the window background.
2. **Structural Tier (Standard Surface Cards & Containers)**: `#FFFFFF`. Elevated purely through a crisp `1.5px solid #DCDCDC` border. Zero shadow. Content cards sit calmly within the canvas.
3. **Focal Tier (Hero Server Modules & Modal Sheets)**: `#FFFFFF` bounded by an authoritative `1.5px solid #1A1A1A` ink border. When lifted during a drag interaction, elements apply a subtle, ultra-diffuse ambient shadow: `0 8px 24px -4px rgba(26, 26, 26, 0.08)`.
4. **Aurora Refraction Tier (Floating Lens & Controls)**: Translucent surface layers with 78% to 85% opacity, combined with a `12px` to `16px` backdrop blur (`backdrop-filter: blur(14px)`). A defining `1.5px` border with a subtle gradient highlight rim captures simulated directional light, giving the floating dock and interactive lenses a luminous physical edge.

## Shapes

The design system employs a disciplined rounded geometry (`roundedness: 2`, with an 8dp base unit) to balance modern software friendliness with structured data layouts.

### Geometry Scale
- **Small Radii (6dp - 8dp)**: Applied to micro technical badges, protocol tags (`HTTP`, `WebDAV`), inline code blocks, thumbnail containers, and dense transfer items.
- **Medium Radii (12dp - 16dp)**: Applied to primary content cards, server metric modules, settings groupings, and alert containers.
- **Large Radii (18dp - 24dp)**: Applied to the top corners of sliding modal sheets and interactive action sheets.
- **Pill (Full 999dp)**: Reserved strictly for transient, floating, and pill-shaped interactive anchors: the 74dp floating dock outer shell, primary action CTA buttons, and status indicator capsules (`ServerStatusChip`).

## Components

### 1. Buttons
- **Aurora Primary Button**: Pill-shaped (height: 48dp), filled with the Primary Aurora gradient (`#8F83D8 → #B58FD0 → #D98FB0`), enclosed in a crisp `1.5px solid #1A1A1A` ink rim. Text is high-contrast Ink Primary (`#1A1A1A`), weight 600. On tap, scales to `0.97` with an 80ms immediate response.
- **Outline / Secondary Button**: Pill-shaped, background `transparent` or `#FFFFFF`, border `1.5px solid #1A1A1A`, text `Ink Primary`. Hover/focus transitions to `#F7F7F5`.
- **Destructive Button**: Background `#FDF6F6`, border `1.5px solid #A34A4A`, text `#A34A4A`. Follows a 3-tier lifecycle for safety (`Delete → Move to Vault Trash → Permanent Shred`).

### 2. Floating Aurora Glass Bottom Dock
- **Dimensions & Placement**: 74dp height (compacts dynamically to 58dp when fast-scrolling lists), floating 16dp above the screen bottom with 16dp lateral margins.
- **Material**: Translucent frosted lens (`rgba(255, 255, 255, 0.82)`, `backdrop-filter: blur(16px)`), framed with a `1.5px solid rgba(255, 255, 255, 0.65)` highlight perimeter and an exterior `1.5px solid #DCDCDC` boundary.
- **Moving Lens**: A floating pill-shaped internal indicator highlights the active item, animated with a physics-based spring curve (420–480ms). Crossing items triggers a light 4–8ms haptic tick.

### 3. Server Status Chip
- **Anatomy**: Compact pill (height: 28dp, padding: 4dp 12dp).
- **States**:
  - *Live*: Background `#FFFFFF`, border `1.5px solid #B0CDB4`, text `#3A7A4A`, typography `JetBrains Mono 11px Medium`. Prepended by a pulsing green glyph: `● Server Live`.
  - *Stopped*: Background `#FFFFFF`, border `1.5px solid #DCDCDC`, text `#666666`. Prepended by a hollow indicator: `○ Stopped`.
  - *Limited / Warning*: Background `#FFFFFF`, border `1.5px solid #DCD0B0`, text `#8A6A2A`. Prepended by: `! Limited`.

### 4. Storage Linear Meter
- **Structure**: 12dp height, fully rounded pill container with `#F0EEE9` fill and a recessed `1px solid #DCDCDC` border.
- **Progress Fill**: Segmented multi-color or Primary Aurora gradient fill indicating usage breakdown (e.g., Photos, Backups, System). Animated linearly during disk read/write events.

### 5. Protocol Chips
- **Anatomy**: Height 24dp, radius 6dp, padding 2dp 8dp. Background `#FAFAFA`, border `1.5px solid #DCDCDC`.
- **Typography**: `JetBrains Mono 10px Medium`, uppercase (`WEBDAV`, `SFTP`, `SMB3`, `HTTP`). When active, transitions to `#EEF3FB` fill with `#2A78D6` border and ink.

### 6. FileRow & TransferRow
- **FileRow**: Height 56dp. Icon indicator (rounded container, 40×40dp), filename in `Inter 14px Regular` with single-line ellipsis, secondary row displaying file size and modified timestamp in `JetBrains Mono 11px` (`Ink Tertiary`). Multiselect highlights the background with `#EEF3FB` and sets the left accent border to `3px solid #2A78D6`.
- **TransferRow**: Displays the active transfer title, real-time speed in `JetBrains Mono 12px` (e.g., `42.5 MB/s`), dynamic ETA, and a micro 4dp linear progress track pinned directly to the bottom boundary.

### 7. Form Inputs & Dropzones
- **Inputs**: Height 48dp, radius 8dp, background `#FFFFFF`, border `1.5px solid #DCDCDC`. Focused state upgrades border to `1.5px solid #1A1A1A` with zero outer ring glow.
- **Dropzones / Staging Areas**: Framed with a prominent `1.5px dashed #1A1A1A` perimeter, `#FAFAFA` fill, and centered handwritten action prompt.