# Contributing

1. `scripts/build-ghostty.sh` once, then `swift build` and `swift test`.
2. Lint with `swiftlint`, format with `swift format -r -i Sources Tests`.
3. Read [docs/architecture.md](docs/architecture.md) first: module boundaries (the app talks to the daemon only through JSON-RPC) are enforced
   by `Tests/ArchitectureTests`.
4. One focused change per pull request, against `main`; new features go in as an extension (see `docs/extensions.md`).
5. What's merged ships in the next Kelp Beta and the next release: [docs/releasing.md](docs/releasing.md).
