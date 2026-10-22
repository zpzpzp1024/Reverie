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

Over SSH from a computer (install OpenSSH from Sileo first; the default root
password is `alpine`):

```sh
scp packages/lilliana.reverie_*_iphoneos-arm64.deb root@<iphone-ip>:/var/mobile/
ssh root@<iphone-ip>
/var/jb/usr/bin/dpkg -i /var/mobile/lilliana.reverie_*_iphoneos-arm64.deb
sbreload
```

On the device, Filza can install a `.deb` directly: open it and choose Install.
Respring after installing or after changing any setting in Settings -> Reverie.

## Sileo source

Each release also publishes a flat repository to the `gh-pages` branch. Enable it
once in the repository settings under Settings -> Pages (Source: "Deploy from a
branch", branch `gh-pages`, folder `/ (root)`), then add the site URL to Sileo.

## Verify

Every event is written to `/var/mobile/Library/Logs/Reverie.log`, which can be
opened in Filza or with `cat`. It rotates at 256 KB.

For live output, the entries are info level, so `--info` is required:

```sh
log stream --info --style compact --predicate 'subsystem == "lilliana.reverie"'
```

Note that a USB cable counts as a charger, so a device connected to a computer
never hibernates. Test on battery, then read the log file afterwards.

Expected sequence when the charger is removed while locked:

```
charger state changed, charging = false
sleeping, reason = autoSlept
IOPMSleepSystem
```
