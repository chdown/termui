# CoderX pty2 fork

This unpublished package is maintained on `codex/coderx-pty2` in `https://github.com/chdown/termui`. CoderX consumes `packages/pty2` at an immutable Git commit recorded in its pubspec and lockfile.

## Provenance

The patches originated in CoderX's vendored MIT-licensed pub.dev `pty2 0.9.0` archive (SHA-256 `32234f132b758ee89f7c2a91ac755d000fbcf998b0651e46b66b460a19dd7c27`). They were merged onto upstream `c5d8002c48f454bb88e50b112c01abf6ca99f800`, which contains `pty2 0.10.0` and the Unix kill ordering fix `c71b8b72150f0dc1b3de112e5f2fdd75248eaa21`. Upstream sends the signal before closing the PTM; preserve that ordering. The upstream license, build hook, native C sources, and tests remain in place.

## Patches

- `PseudoTerminal.start(initialCols:, initialRows:)` creates the native PTY at the requested geometry. Do not immediately resize to the same geometry: ConPTY would repaint again.
- The reader waits for ACK only after emitting decoded text. Partial UTF-8 reads continue. `beginDrain()` waits for the reader handshake and disables ACK pacing during teardown; `kill()` also releases pacing.
- `createInputWriter(onError)` creates a lazy background writer. It duplicates the input fd/HANDLE, preserves ordering and Unicode, checks native write counts, and bounds pending input. The synchronous `write()` API remains available. Close the writer explicitly; when input is blocked, kill the PTY before awaiting writer shutdown.
- On Windows the output reader owns its read handle and the exit waiter owns the process handle. Claim the ConPTY handle under the lock, then close it outside the lock so the reader can keep draining. Unix writers own a duplicated close-on-exec fd.

## Updating from upstream

Fetch `https://github.com/jtmcdole/termui`, merge a reviewed upstream commit into `codex/coderx-pty2`, and resolve conflicts against these contracts. Keep this maintenance branch's history so CoderX's pinned commits remain available. Do not replace the package directory with a release archive.

Run `flutter pub get` at the repository root. In `packages/pty2`, run `dart format .`, `dart analyze --fatal-infos`, and `dart test`. Also run the four `termui_pty` tests and `apps/termui_cast/caster_cli/test/caster_service_test.dart`, whose fake terminals implement the public interface. The `CoderX pty2 contracts` workflow runs package formatting, analysis, and native tests on Windows, macOS, and Linux for pushes to the maintenance branch. Local Windows verification passed; POSIX-specific cases require their respective CI runners.

After pushing the tested commit, update CoderX's Git `ref`, run `flutter pub get`, and commit its pubspec and lockfile together. Re-run CoderX's terminal transport contracts and the Windows layout test with `CODERX_CONPTY_LAYOUT_RUNS=20`. Never restore a path dependency for a released build.
