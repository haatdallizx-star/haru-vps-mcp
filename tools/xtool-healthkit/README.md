# xtool HealthKit background-delivery patch

`xtool` ([xtool-org/xtool](https://github.com/xtool-org/xtool)) sign / resigns
IPAs by talking to Apple Developer Services to register a bundle ID, attach
capabilities, and fetch a provisioning profile. When resigning with a free
Apple ID / Personal Team, registration happens on the account's behalf.

## The problem

HealthBridge's entitlements contain:

- `com.apple.developer.healthkit` → `true`
- `com.apple.developer.healthkit.background-delivery` → `true`

Upstream xtool only has a registered entitlement type for the first key.
`com.apple.developer.healthkit.background-delivery` is *not* in
`EntitlementContainer.supportedTypes`, so it is unrecognized. On the free-team
path, `DeveloperServicesAddAppOperation.addApp` rebuilds `Entitlements` from the
list of *recognized* entitlements (to avoid re-reading from disk later); the
unrecognized key is silently dropped there. Result: enabling `background-delivery`
in Xcode works because Xcode talks to the portal directly, but resigning via
xtool on a Personal Team loses the entitlement → the dropped `background-delivery`
either doesn't get granted or the resulting profile/app is inconsistent.

## The fix (upstream patch)

Two changes, both minimal:

1. Register a new entitlement type for the background-delivery key so the
   decoder recognizes it:
   - `Sources/XKit/Model/Entitlements/EntitlementTypes.swift`
   - add to `EntitlementContainer.supportedTypes` + define
     `HealthKitBackgroundDeliveryEntitlement` (a `Bool` `RawRepresentable`, same
     shape as `HealthKitEntitlement`).

2. Map it onto the HealthKit capability, marked free-team-eligible:
   - `Sources/XKit/DeveloperServices/App IDs/Entitlements/DeveloperServicesCapability.swift`
   - `HealthKitBackgroundDeliveryEntitlement: EntitlementWithCapability` →
     `DeveloperServicesCapability(.healthkit, isFree: true)`.

Apple has no separate HealthKit background-delivery *capability* in the
Developer API — it is a sub-feature of the `HEALTHKIT` capability. Mapping both
entitlements to the same capability type lets `upsertApp`'s
`uniquingKeysWith` collapse them into a single `HEALTHKIT` capability instead of
registering it twice. The `isFree: true` (matching base HealthKit) keeps it from
being filtered out of free Personal Teams.

Other capabilities (`aps-environment`, app groups, etc.) are deliberately
untouched.

## Patch origin

- Upstream repo: `xtool-org/xtool`
- Pinned commit: `2d58d987edff728fccebc6df643b1672e3583f00` (`1.17.0-8-g2d58d98`)
- Patch file: `0001-healthkit-background-delivery.patch`
- Pin file: `upstream.pin`

The patch was generated with `git diff` from a checkout of that exact commit, so
it applies with `git apply` cleanly. Re-verify with `git apply --check` after
any upstream bump. The helper's `prepare` command does this check automatically.

## Rebuild a patched xtool

```bash
# Requires Swift 6 toolchain. On Linux, requires Docker (upstream's Dockerfile
# 'dev' stage builds libimobiledevice + libxadi).
./build-patched-xtool.sh all
```

On macOS (if used) this builds a native `xtool` at `.work/xtool/.build/release/xtool`.
On Linux/Windows-WSL the same path is produced under the Docker container
`xtool-healthkit-dev:<XTOOL_COMMIT-prefix>` (tag is bound to the pinned commit,
so a pin bump rebuilds the image; the source checkout is bind-mounted so the
binary is on your disk).

## Authentication

The patched xtool talks to Apple Developer Services, so a signing/install run
needs account access. The `password` auth mode takes:

- your Apple ID **email address**,
- your normal **Apple ID password**, and
- the **2FA code** that Apple sends.

This is not an app-specific password, and the `password` mode drives Apple's
**private Developer Services API** (same route Xcode's free-team signing uses).
Note accordingly if you ever need to review the implications. **Phase 2C would
be the first time anything here actually logs in — that is intentionally not
done in this phase.**

## Phase 2C (device signing + install) — not in scope here

Planned path is the original **Windows / WSL** route, not macOS.

What has been verified so far is the **raw release binary built inside the
`xtool-healthkit-dev` container** (see `build-patched-xtool.sh`). That raw binary
is produced for running inside dev; Phase 2C still has to decide whether to run
in the container or package it (e.g. as an AppImage) before it can be treated as
usable on the WSL host directly. No promise is made that the raw dev-container
binary runs on the WSL host out-of-the-box.

Connect the device from WSL via one of:

**A. USBIPD → WSL local usbmuxd**

Pass the iPhone's USB through to the WSL VM (USBIPD) so the device shows up in
WSL's own `usbmuxd` (the `usbmuxd` running inside WSL). This is the "local
usbmuxd" route — no Windows-side relay.

**B. Windows iTunes / Apple Devices → portproxy → WSL `USBMUXD_SOCKET_ADDRESS`**

When the Windows iTunes / Apple Devices usbmuxd listens on **27015**, expose that
to the WSL VM with `netsh interface portproxy`, then point the tool at it inside
WSL:

```bash
export USBMUXD_SOCKET_ADDRESS="$(ip route list default | awk '{print $3}'):27015"
```

This address is the **Windows host / default gateway as seen from inside WSL**,
not WSL's own address.

Reference for the WSL setup:
<https://github.com/xtool-org/xtool/issues/19#issuecomment-2898986718>

> Note: **do not** describe the `socat … UNIX-CLIENT:/var/run/usbmuxd` form as a
> Windows/IPC relay for the iTunes path. That only forwards the **WSL-local**
> usbmuxd socket so a container can reach it; it is unrelated to exposing the
> Windows iTunes usbmuxd.

Then authenticate per the section above, sign `HealthBridge.ipa`, and install.

None of Phase 2C is executed in this phase: no login, no Apple ID credentials,
no device, no production VPS.

## Tests

The test file is `Tests/XToolTests/HealthKitEntitlementTests.swift` in the patch.
It covers:

- `HealthKitEntitlement` still maps to `HEALTHKIT`, `isFree: true`.
- `HealthKitBackgroundDeliveryEntitlement` maps to the *same* `HEALTHKIT`
  capability type, `isFree: true`.
- The background-delivery entitlement is recognized when decoding an
  entitlements plist.
- It survives the free-team filter (the exact regression).
- The two HealthKit entitlements collapse to one capability.
- Unrelated capability behavior is unchanged (`aps-environment` is still
  mapped and still filtered out for free teams).
- An unregistered sibling key stays unrecognized (the patch widens recognition
  by exactly one key).
