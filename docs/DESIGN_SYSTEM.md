# Design System: Abyssal Instruments

## Overview
A dense, instrument-grade UI for technical divers. The system favors clarity, compact layouts, and precise data presentation, with restrained color and strong hierarchy.

## Typography
- **Display/Headings**: Fraunces
- **Body/UI**: IBM Plex Sans
- **Monospace**: IBM Plex Mono

### Type scale (sp)
- 12, 14, 16, 20, 24, 32

### Usage
- H1: 32 / 36
- H2: 24 / 28
- H3: 20 / 24
- Body: 16 / 22
- Small: 14 / 20
- Micro: 12 / 16
- Data mono: 12 / 16 or 14 / 18

## Color
Base palette uses deep slate and high-contrast text.

- **Ink**: #0E1114
- **Panel**: #151B20
- **Surface**: #1D242B
- **Text**: #E7EDF3
- **Muted**: #A7B3BF
- **Cyan**: #3FB8C5
- **Orange**: #F77F00
- **Green**: #3AAE6A
- **Red**: #D64545
- **Chart subtle**: #5D6B76

## Layout
- Desktop margins: 24–32 px
- Mobile margins: 16 px
- Grid: 8 px base unit
- Density modes: Field (dense) and Brief (relaxed)

## Components
- **Instrument card**: compact stats, hard edges, subtle inner shadow
- **Filter chips**: pill-rect; active = cyan border + solid fill
- **Tables**: zebra rows, right-aligned numeric columns
- **Charts**: inked lines, thin gridlines, annotated events
- **Tags**: flat pills with category colors

## Segment selection UX
- Drag-to-select range on depth chart to create a segment.
- Quick actions: Rename, Tag, Save, Clear.
- Segment stats drawer shows avg depth, time at setpoint, CNS/OTU, and deco time.
- Multiple segments allowed per dive with color-coded overlays.

## Preferences UX
- Settings groupings: Display, Units, Sync, Data.
- Time format toggle shows a live preview (e.g. `MM:SS` vs `HH:MM:SS`).
- Defaults favor compact CCR workflows (Field density, metric/imperial toggle).

## Motion
- Staggered reveal for dashboard cards
- Graph draw on detail view
- Transitions 120–180 ms, ease-out

## Accessibility
- Minimum text contrast ratio 4.5:1
- Large type support via platform scaling
- Keyboard-first navigation on desktop
