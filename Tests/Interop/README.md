# Interoperability with SwiftyXPC 0.5

SwiftyXPC 1.0 keeps the 0.5 wire format, so a 1.0 app can talk to a 0.5 helper and the other way round. The unit tests
in `WireCompatibilityTests` pin the format down with hand-built messages. The two clients here check it end to end,
against real builds of both versions:

| Client | Built with | Talks to |
|---|---|---|
| `LegacyClient` | SwiftyXPC 0.5.105, fetched from GitHub | the `TestHelper` of this checkout |
| `CurrentClient` | this checkout | the `TestHelper` of 0.5.105 |

Each client runs the same checks — request and response, nested `Data`, a handler error, process identifiers, a one-way
message, an unknown message name, and a listener endpoint that the helper calls back — prints `PASS` or `FAIL` for each,
and exits with the number of failures. The two places where 1.0 behaves differently are part of the checks:

- A 1.0 receiver answers an unknown message name with `XPCConnection.Error.unexpectedMessage`; a 0.5 receiver never
  answers, so its sender sees `XPCError.connectionInterrupted`.
- A 0.5 receiver answers every one-way message with a nameless message of its own. A 1.0 sender ignores it; a 1.0
  receiver never sends it.

None of this is part of `swift test`: the clients need a different version of the library than the package they sit in.

## Running the checks

Builds go to a scratch path of your choice; the commands below use `/tmp/SwiftyXPC-Interop`. Both helpers register the
same Mach service as the unit tests, `com.charlessoft.SwiftyXPC.TestHelper`, so do not run `swift test` at the same time.

```bash
SCRATCH=/tmp/SwiftyXPC-Interop
INTEROP="$(git rev-parse --show-toplevel)/Tests/Interop"

# The 0.5.105 helper, from a clean export of the tag.
mkdir -p "$SCRATCH/SwiftyXPC-0.5.105"
git archive 0.5.105 | tar -x -C "$SCRATCH/SwiftyXPC-0.5.105"
swift build --package-path "$SCRATCH/SwiftyXPC-0.5.105" --scratch-path "$SCRATCH/legacy-helper" --product TestHelper

# The current helper and both clients.
swift build --scratch-path "$SCRATCH/current-helper" --product TestHelper
swift build --package-path "$INTEROP/LegacyClient" --scratch-path "$SCRATCH/legacy-client"
swift build --package-path "$INTEROP/CurrentClient" --scratch-path "$SCRATCH/current-client"

# A launchd job for each helper.
for version in legacy current; do
    helper="$(swift build --scratch-path "$SCRATCH/$version-helper" --show-bin-path \
        $([ $version = legacy ] && echo --package-path "$SCRATCH/SwiftyXPC-0.5.105"))/TestHelper"
    plutil -create xml1 "$SCRATCH/$version-helper.plist"
    plutil -insert Label -string com.charlessoft.SwiftyXPC.TestHelper "$SCRATCH/$version-helper.plist"
    plutil -insert Program -string "$helper" "$SCRATCH/$version-helper.plist"
    plutil -insert MachServices -json '{"com.charlessoft.SwiftyXPC.TestHelper": true}' "$SCRATCH/$version-helper.plist"
    plutil -insert KeepAlive -bool true "$SCRATCH/$version-helper.plist"
done

# 0.5.105 client against the current helper.
launchctl load "$SCRATCH/current-helper.plist"
"$(swift build --package-path "$INTEROP/LegacyClient" --scratch-path "$SCRATCH/legacy-client" --show-bin-path)/LegacyClient"
launchctl unload "$SCRATCH/current-helper.plist"

# Current client against the 0.5.105 helper.
launchctl load "$SCRATCH/legacy-helper.plist"
"$(swift build --package-path "$INTEROP/CurrentClient" --scratch-path "$SCRATCH/current-client" --show-bin-path)/CurrentClient"
launchctl unload "$SCRATCH/legacy-helper.plist"
```

Both clients must end with `0 failed`.
