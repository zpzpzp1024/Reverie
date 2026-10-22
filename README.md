# Reverie

Hibernates a jailbroken iPhone so it can live in a car without draining the
battery, and wakes it when the car powers the dock back up.

Reverie suspends the SoC with `IOPMSleepSystem`, which is deeper than turning the
screen off: while it is asleep the device is not reachable by Find My or remote
commands. Attaching a charger is the only automatic wake source, so the tweak is
built around the assumption that the car cuts power when it is turned off.

## Behaviour

| Event | Action |
| --- | --- |
| Charger attached | exits hibernation (screen stays off) |
| Power removed, device locked, no CarPlay, 9 s grace | hibernates |
| Volume up ×5, CC toggle, prefs toggle | manual wake: screen on, unlocked, 90 s hold before auto-sleep |

- The 9 s grace period covers the head unit finishing its shutdown. CarPlay is
  detected through the extra `UIScreen` SpringBoard gets while a session is live.
- Wireless CarPlay needs Bluetooth and Wi-Fi, so airplane mode is never toggled.
  Add `Sleep While CarPlay Active` only if you never use CarPlay.
- `Sleep Only While Locked` (default on) prevents hibernation while the device is
  in use; with it off the device will hibernate on unplug even when unlocked.

## Requirements

- iOS 13 or later, rootless jailbreak (Dopamine, palera1n rootless)
- ElleKit or another `mobilesubstrate` provider
- PreferenceLoader, CCSupport

## Build

The build runs on macOS and needs Theos with the `iPhoneOS16.5.sdk` SDK, the
`theos/headers` submodule and `ldid` in `PATH` (set `THEOS_SDK` to override the
SDK directory name):

```sh
make setup          # vendor Jinx and JinxPrefs
make package FINALPACKAGE=1
```

The package lands in `packages/`. CI (`.github/workflows/build.yml`) does the same
on every push and uploads the `.deb` as an artifact; tag pushes also attach it to
the GitHub release.

You need Theos with `iPhoneOS16.5.sdk`, `ldid` in `PATH`, and the `theos/headers`
submodule. Set `THEOS_SDK` to override the SDK directory name.

## Install

```sh
sileo install ./packages/lilliana.reverie_*_iphoneos-arm64.deb
```

Respring after installing or after changing any setting in Settings → Reverie.

## Verify

```sh
log stream --predicate 'subsystem == "lilliana.reverie"'
```

The log reports the charger transitions, every refused sleep (CarPlay active, no
power connection), and each `IOPMSleepSystem` call.
