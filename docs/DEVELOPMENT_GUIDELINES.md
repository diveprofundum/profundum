# Development Guidelines

## Project values
- Open source by default; avoid lock‑in.
- Local‑first and privacy‑respecting.
- Clear, reviewed, deterministic builds.

## Workflow
- Use small, reviewable pull requests.
- Keep docs updated with architectural changes.
- Add tests for new core functionality.

## Licensing
- Prefer permissive OSS licenses for dependencies.
- Avoid copyleft dependencies in the core unless explicitly approved.
- Document all third‑party licenses in a `THIRD_PARTY.md` file.

## Code style
- Rust: `rustfmt` + `clippy` clean.
- Kotlin/Swift: follow platform conventions and keep APIs idiomatic.
- Keep public APIs backward‑compatible where possible.

## Compatibility
- Version the UniFFI API surface.
- Never break the storage schema without a migration.

## Security
- No network calls without explicit user action.
- Store logs locally; cloud is opt‑in.

## Contribution
- Use clear commit messages.
- Include a short rationale in PR descriptions.
