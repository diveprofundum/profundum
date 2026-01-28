# UX Acceptance Criteria (Draft)

## 1) Onboarding → BLE permissions
- User can proceed without creating an account.
- BLE permission prompt appears only after context is explained.
- If permission is denied, user sees guidance and can retry.
- Device list refreshes within 3 seconds of enabling BLE.

## 2) First sync → first dive
- Sync progress shows current dive count and estimated remaining time.
- User can cancel sync and resume later without data loss.
- After sync, a success screen lists imported dives and last sync time.
- Dive list opens filtered to last 30 days or recent imports.

## 3) Dive detail → segment workflow
- User can drag on the depth profile to create a segment.
- Segment can be named, tagged, and saved in under 3 taps.
- Segment stats update within 100 ms of selection.
- Deleting a segment requires confirmation.

## 4) Formula creation → list columns
- Formula editor highlights invalid syntax within 50 ms.
- Preview shows a real dive sample value.
- Formula can be applied to all dives or a filtered subset.
- Columns can be reordered and hidden.

## 5) Settings → time format
- Toggle updates visible durations immediately.
- User preview shows before/after examples.
- Setting persists across app restarts.

## 6) Failure and recovery (BLE)
- Sync failures show clear error and cause (if known).
- User can retry without restarting the app.
- Resume continues from last successfully downloaded dive.

## 7) Data management
- User can create/edit sites, buddies, and equipment.
- Linking is available directly from the dive detail view.
- Filters allow searching by site, buddy, or equipment.
