# Development Guidelines

## Project values
- Open source by default; avoid lock‑in.
- Local‑first and privacy‑respecting.
- Clear, reviewed, deterministic builds.

## Open source commitment

### Prefer open source tools
- Choose open source libraries and tools over proprietary alternatives.
- Use standard protocols and open formats: UDDF, Subsurface XML, standard BLE profiles.
- Avoid vendor-specific APIs when open standards exist.
- SQLite over proprietary databases; open parsers over closed SDKs.

### Contribute upstream
- When patching a dependency, open a PR upstream rather than maintaining a private fork.
- Report bugs to upstream projects with minimal reproduction cases.
- If upstream is unresponsive, document the fork rationale in `THIRD_PARTY.md`.

### Design for community
- Modular architecture that allows third-party extensions (e.g., dive computer parsers).
- Document architectural decisions in `docs/DECISIONS.md` for transparency.
- Write clear APIs that external contributors can understand and extend.
- Welcome contributions for additional device support, import formats, and analytics.

## Workflow
- Use small, reviewable pull requests.
- Keep docs updated with architectural changes.
- Add tests for new core functionality.

## Licensing
- Prefer permissive OSS licenses (MIT, Apache-2.0, BSD) for dependencies.
- Avoid copyleft dependencies in the core unless explicitly approved.
- Document all third‑party licenses in `THIRD_PARTY.md`.
- Contributions are licensed under the project license (MIT).

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
