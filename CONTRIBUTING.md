# Contributing

Thanks for your interest in Profundum.

## Getting Started

1. Clone the repo (with submodules): `git clone --recurse-submodules`
2. Install the Rust toolchain: [rustup.rs](https://rustup.rs)
3. Build: `make all`
4. Run tests: `make test`

## Pull Requests

- Create a feature branch from `main`
- Keep PRs focused and small
- Include a clear summary and rationale
- Add or update tests when changing core logic
- CI must pass (`swift-test`, `version-check`) before merge

## Code Style

- **Rust**: `cargo fmt` + `cargo clippy` clean (`make lint`)
- **Swift**: follow existing patterns — GRDB records use `Codable + FetchableRecord + PersistableRecord` with explicit `CodingKeys`

## Reporting Issues

- Use GitHub Issues
- Provide reproduction steps and expected behavior
- Include OS version, device info, and logs when relevant

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](LICENSE).
