## What and why

<!-- One or two sentences: what this PR changes and why. Link the issue: "Closes #123". -->

## Area

- [ ] `desktop/` (Rust agent)
- [ ] `mobile/` (Flutter app)
- [ ] `docs/PROTOCOL.md` (wire protocol)
- [ ] Docs / CI / repo

## Protocol checklist

<!-- Skip if the wire format is untouched. -->

- [ ] This PR does **not** change anything on the wire, **or**
- [ ] `docs/PROTOCOL.md` is updated, the protocol version `v` is bumped if old peers would break, and **both** `desktop/` and `mobile/` implement the change in this PR.

## How I tested it

<!-- Devices and OS versions, e.g. "iPhone 15 / iOS 26 -> MacBook Air M3 / macOS 26". -->

- Phone:
- Computer:
- Steps:

## Checklist

- [ ] `cargo fmt`, `cargo clippy` and `cargo test` pass in `desktop/` (if touched)
- [ ] `flutter analyze` and `flutter test` pass in `mobile/` (if touched)
- [ ] UI changes follow `docs/DESIGN.md` (tokens, motion, haptics, reduce-motion)
- [ ] Screenshots or a short recording are attached for visible changes
- [ ] Commit messages follow Conventional Commits (`feat(mobile): ...`)
