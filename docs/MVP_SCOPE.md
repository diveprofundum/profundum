# MVP Scope (Draft)

## Goal
Ship a v1 that reliably imports Shearwater dives over BLE on all platforms and delivers a fast, data‑dense CCR log with segment analytics and core tagging.

## Must‑have (v1)
### Core ingest
- BLE discovery, pair, and sync from Shearwater computers.
- Incremental sync (new dives only).
- Robust error handling with retry and resume.

### Core data
- Dive list and detail view.
- Depth profile graph with annotations (setpoint/gas switches).
- Tags on dives and segments.
- Sites, buddies, and equipment entities with basic metadata.

### Segment analytics
- Create/edit/delete segments on depth profile.
- Segment stats: avg depth, time, CNS/OTU, deco time.
- Segment selection retained per dive.

### Formulas
- Define formulas with validation.
- Apply formulas to dives and show in list columns.
- Basic formula library (examples + templates).

### Settings
- Units (metric/imperial) and time format.
- BLE permissions and device management.

## Should‑have (v1 if time)
- Year‑in‑review summary cards.
- Service reminders (O2 cells, scrubber, cylinder hydro).
- Advanced filter grammar.

## Out of scope (v1)
- Cloud sync.
- CSV/Subsurface/UDDF import/export.
- Team sharing or multi‑user features.
- Media attachments (photos/video).
- AI summaries.

## Success criteria
- Sync 50 dives from a Shearwater device in under 3 minutes.
- Dive list filters respond under 100 ms for 10k dives.
- Segment creation and stats update within 100 ms.
- Formula validation feedback under 50 ms.

## Risks
- Platform BLE differences causing inconsistent pairing behavior.
- Chart performance for long dives with dense sampling.
- Formula engine edge cases (divide by zero, missing values).
