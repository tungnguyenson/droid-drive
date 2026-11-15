# Phase 0 spike results

This document records the answers to the four yes/no questions of phase 0 in [`plan.md`](plan.md): the questions whose "no" would force a design change in [`spec.md`](spec.md). Each spike lists the question, how it was tested, the machine and versions, the result, and what it means for the design. It also collects the later measurements on the emulator and on a real phone. Testing started on 14 November 2026.

Unlike the original plan, S0-b and S0-c were not throwaway programs: their code became the phase 1 packages (`AdbKit`, `ItemStore`, the File Provider extension) and was kept. Spikes that need a real phone on a USB cable have not been run, because the test Mac has had no phone plugged in.

## Test setup

| | |
|---|---|
| Mac | MacBook Pro, Intel Core i7-9750H, 16 GB RAM, macOS 26.7.2 (25G332) |
| Tools | Xcode 26.6, Swift 6.3.3, XcodeGen, adb from platform-tools |
| Phones | Android Emulator `Pixel_4_XL`, image `android-35/google_apis/x86_64` (Android 15); later a real Pixel 4 XL (Android 13) over Wi-Fi |
| Signing | "Apple Development" certificate of the developer's individual team, local signing without a provisioning profile (the FSKit spike needed one, see S0-d) |

## Summary

| Id | Question | Answer | Consequence |
|---|---|---|---|
| S0-a | Can `IOUSBHost` open the MTP interface while `ptpcamerad` runs? | **Not tested yet**: the `droiddrive-usb` tool is ready, a real phone on a cable is needed | Blocks P2-01 onwards on real hardware; ADB stays the main route |
| S0-b | Can we write our own ADB handshake up to `sync:` `LIST`? | **Yes, over TCP**. The USB part (UsbKit) has only run against a fake USB pipe | Keep decision 4 (own ADB client). The protocol layer does not depend on the link; USB only adds an `AdbPacketLink` |
| S0-c | Does a replicated File Provider show in Finder, read, write, rename, and queue while disconnected? | **Yes**, with one condition: macOS 26 creates domains disabled, and the user must enable them | A "turn DroidDrive on" step in the guidance and in the menu (done) |
| S0-d | Can FSKit mount a file system not backed by a block device? | **Yes**: mounted from the URL `droidspike://`, listed 10,000 entries in 0.11 seconds (File Provider: 401 seconds) | On macOS 26.x users cannot enable a third-party module (a macOS bug, fixed in 27.0); a sandboxed app cannot mount by itself. Not adopted |

## S0-b: our own ADB client

**How.** `droiddrive-cli` (target `DroidDriveCLI` in `Packages/`) opens TCP to the emulator's adbd (`127.0.0.1:5555`, with the adb server stopped), sends `CNXN`, signs `AUTH TOKEN` with `~/.android/adbkey`, opens `sync:` and `shell,v2,raw:`. Then the same through the adb server (`host:transport:<serial>`), the route P1-08 needs.

**Results.**

- Handshake, AUTH by signature, `LIS2`/`STA2`/`LST2`, `RECV`, `SEND` and `shell,v2` all work, both directly and through the adb server.
- The Android-format public key our code generates matches `adb pubkey` **byte for byte** (test `AdbKeyTests`).
- The "Allow USB debugging?" path (sending `RSAPUBLICKEY` and waiting for the user) is only tested against a fake adbd, because the emulator already trusts adb's key.
- The protocol v1 paths (`LIST`, `STAT`, `shell:` without v2) work when the v2 features are hidden from the emulator (test `LegacyProtocolTests`). Not yet tried on a real old Android phone.

**Speed, 1 GB random file, release build, same emulator** (spec section 9 asks for ≥ 80% of `adb`):

| | push | pull |
|---|---|---|
| `adb` | 160–172 MB/s | 105–110 MB/s |
| DroidDrive through the adb server | 181–193 MB/s | 90–114 MB/s |
| DroidDrive connected directly | 174–177 MB/s | 94–111 MB/s |

SHA-256 matches after every round trip, and mtime is kept to the second (FR-09). Emulator numbers are only for relative comparison; a real phone on a USB cable must be measured in P1-14.

**Listing a 10,000-file folder** through the adb server: first page (500 entries) after 0.13 seconds, the whole folder after 1.6 seconds (targets ≤ 2 and ≤ 15 seconds).

**Bugs found and fixed during the spike:**

1. The stream reader copied the whole buffer after every 64 KB chunk, O(n²). Pull first reached only 63% of `adb`'s speed.
2. Opening a service through the adb server: data arriving in the same TCP packet as "OKAY" was dropped. Sync was not affected, `shell:` was.
3. Overwriting a large file reported "no space", because the free-space check did not subtract the old file's size.
4. An OKAY arriving while a packet was being sent was lost and the stream hung (race).
5. A handshake timeout did not cancel the pending read and hung forever.

**Done later:** the ADB key moved to the Keychain (`AdbKeyStore`). **Not done:** the USB route on a real phone (`UsbKit`, P1-03), a 6 GB file (the emulator only has 3.3 GB free).

## S0-c: replicated File Provider

**How.** The menu-bar app (`App/`) creates one domain per storage of the emulator. The extension (`FileProvider/`) talks to the emulator through the adb server. Every operation is run from Terminal on `~/Library/CloudStorage/DroidDrive-…`, the same path Finder uses, and checked on the phone with `adb shell`.

**Results.**

| Task | Result |
|---|---|
| FR-03: one drive per storage | Two items, `sdk_gphone64_x86_64 · Internal storage` and `· SD card 0000-0000` |
| FR-04/05: browse, open files | Pass |
| FR-06: create files and folders, rename, move, edit, delete | Pass, each operation visible on the phone after a few seconds |
| FR-08: Vietnamese names from the Mac (NFD) | Arrive on the phone as NFC (checked with `od -c`) |
| FR-10: disconnect, downloaded files still open, edit, reconnect | The edit reaches the phone 3 seconds after reconnecting |
| FR-11: the phone adds a file | Shows on the Mac within the 30-second refresh interval (measured 18 seconds) |
| Conflict: the Mac edits a stale copy while the phone has changed | The phone's version is kept; the Mac's becomes `phone (Mac copy).txt`; Finder shows both |

**What affects the design:**

1. **macOS 26 creates domains "user-disabled".** Until the user turns DroidDrive on under System Settings → General → Login Items & Extensions → File Providers, every operation in the folder times out and the extension never starts. No API or command can turn it on for the user (`fileproviderctl` has none). The menu now detects `userEnabled == false` and has a button that opens that settings page. P4-01 needs a screenshot for this step.
2. **Folders created from the Mac are never listed by Finder**, because Finder already knows their contents. If refresh only covered listed folders, files the phone adds to them would never appear. Fixed: folders created from the Mac are marked for refresh.
3. **Creating a file with the same name as a file Finder does not know about** (the phone just created it): returning `filenameCollision` left the file stuck on the Mac. Changed: keep both, the Mac's copy goes up under the conflict name; a same-named folder is merged.
4. **Appending to a file that was not downloaded** makes macOS fetch the latest version before editing, so it is not a conflict. Conflicts only happen when the Mac holds a stale downloaded copy.
5. Local signing with an Apple Development certificate, without a provisioning profile, is enough to run the extension and the app group during development.

**Temporary deviation, now resolved:** the extension first connected to the adb server by itself instead of going through the app over XPC as spec section 5.1 says. That worked because the adb server, not DroidDrive, held the USB interface. On the evening of 14 November 2026 the app took over the connections and the extension now calls it over XPC; the link differs from the original design, see spec section 5.1.

## Real phone over Wi-Fi (evening of 14 November 2026)

**Phone:** Pixel 4 XL, Android 13, 50 GB (37 GB used), no SD card. Paired with platform-tools' `adb pair` (6-digit code), after which the adb server connected through mDNS by itself; DroidDrive saw the phone through the adb server and mounted one drive, "Pixel 4 XL · Internal storage". All writes stayed inside `/storage/emulated/0/DroidDriveTest`, deleted afterwards.

**Integration tests** (`DROIDDRIVE_TEST_ROOT=/storage/emulated/0/DroidDriveTest`): 7 of 8 pass. The 10,000-file folder lists completely in 8.3 seconds (target 15), but the first page took 2.27 seconds (target 2) while the speed test was running at the same time and sharing bandwidth; to be measured again alone. Creating 10,000 files with `xargs touch` on a real phone takes most of that test's time (20 minutes in total).

**Speed over Wi-Fi, 100 MB file, run alone:**

| | DroidDrive | `adb` | Ratio |
|---|---|---|---|
| pull | 1.7 MB/s | 1.9 MB/s | 89% |
| push | 3.0 MB/s | 2.8 MB/s | 107% |

The Wi-Fi network here is slow (2–3 MB/s with `adb` too). A 300 MB file there and back matches SHA-256 and keeps its mtime.

**Through Finder:** creating files and folders with Vietnamese names (NFC on the phone), renaming, moving, editing and deleting a whole folder all work; a file created on the phone shows on the Mac after 4 seconds; a conflict keeps the phone's version and uploads the Mac's as `tu-dien-thoai (Mac copy).txt`. By then the app was running the XPC architecture.

**Bug found:** a `droiddrive-cli` built before fix 2 above (data arriving in the same TCP packet as the adb server's "OKAY" was dropped) reported "the device closed the stream early" about 1 time in 20. Over slow Wi-Fi a shell command's output often arrives in the same packet as "OKAY". Current code: 40 of 40 runs correct. This only shows on a real network; the emulator does not reproduce it.

**Pairing with DroidDrive itself** ("Connect via Wi-Fi…" window, QR tab): the user scanned the code with the Pixel and pairing succeeded. DroidDrive connected over TLS by itself and remounted the same drive; the menu shows "Pixel 4 XL (ADB · Wi-Fi)". Through Finder on this route: listing, creating folders and files with Vietnamese names, renaming, editing, uploading 20 MB in 11.4 seconds (1.8 MB/s, on par with `adb` on this network) and deleting a whole folder all pass, according to the transfer log and the following refresh.

Observation, not yet verified: once DroidDrive held the TLS connection, the adb server lost the phone (`adb devices` empty) and `adb connect` to the port the phone advertised failed. Android may accept only one wireless debugging client at a time. If so, Android Studio users would see DroidDrive and adb compete for the phone over Wi-Fi; to be retested and recorded in the spec.

## App measurements on the emulator (P4-06, on a heavily loaded Mac, load average 4–138)

- **Transfer speed at the transfer layer, 200 MB:** upload 30 and 96 MB/s against `adb push` 28 and 26 MB/s; download 75 and 152 MB/s against `adb pull` 83 and 97 MB/s. End to end through Finder: up 21–65 MB/s, down 42–60 MB/s.
- **Listing a folder opened for the first time in Finder:** 300 entries 10–11 seconds, 1,000 entries 30 seconds, 10,000 entries 401 seconds. The extension serves each 500-entry page in under 0.25 seconds; the time is fileproviderd creating a placeholder file per entry, about 30 ms each (3,803 such jobs queued). Turning the badge off changed nothing. Meanwhile, uploads to the same drive wait.
- **Memory:** extension 16–17 MB, app 40–55 MB. **CPU when idle:** 0.96% with 3 drives of 2 phones.
- **FR table on the emulator:** FR-03, 05, 06 (each operation 0.7–1.8 seconds), 08, 09, 10 (with the app quit and relaunched: uploaded 2 seconds later), 11 (30.1 seconds, the refresh interval), 17, 18, 19, 20 pass; FR-04 is complete but slow as above.

## USB and MTP: only tested against a fake phone

`UsbKit`, `MtpKit` and `droiddrive-usb` are written and tested, but only against an in-memory fake MTP phone (behaving like Android's MtpServer where it differs from the standard) and fake USB pipes. Opening a real USB interface has only been compiled. The read-only parts did run for real: `droiddrive-usb list` and `watch` enumerate this Mac's 12 USB devices correctly, and a test checks that `UsbInterfaceOpener` refuses every non-Android interface (keyboard, trackpad) before calling IOUSBHost.

The first commands to run with a real phone on a cable (S0-a, P2-09):

```sh
cd Packages
swift run droiddrive-usb list
swift run droiddrive-usb mtp-info            # then again after: killall ptpcamerad; also try --seize
swift run droiddrive-usb mtp-ls /storage/emulated/0/DCIM
swift run droiddrive-usb adb-info            # the adb server must not hold the ADB interface
```

## S0-d: FSKit with a URL resource (14–15 November 2026)

**Question.** Can FSKit on macOS 26 mount a file system not backed by a block device? It was done early because listing large folders through File Provider misses spec section 9 (fileproviderd spends about 30 ms per entry).

**On paper: yes.**

- The macOS 26 SDK has `FSGenericURLResource` (any URL, schemes declared with `FSSupportedSchemes`) and `FSPathURLResource`, both `API_AVAILABLE(macos(26.0))`.
- macOS 26.7 ships `com.apple.fskit.ftp.appex`, which mounts FTP exactly this way: `FSSupportsGenericURLResources = true`, `FSSupportsBlockResources = false`, `FSSupportedSchemes = [ftp]`. Mounted with `mount -F -t <FSShortName> <url> <mount point>`.

**The spike** lives in `spikes/fskit/` (its own XcodeGen project): a minimal host app and the extension `DroidSpikeFS` (`UnaryFileSystemExtension`, `FSUnaryFileSystem`, a read-only `FSVolume`). It generates in memory a folder `many/` with N files, mounted from `droidspike://test?files=10000`.

**Findings:**

- The `com.apple.developer.fskit.fsmodule` entitlement needs a provisioning profile: local signing without one is refused by Xcode ("requires a provisioning profile with the FSKit Module feature"). Automatic signing with the developer's team creates a profile with it.
- macOS registers the module (`pluginkit -m -p com.apple.fskit.fsmodule` lists it). System Settings shows it under the app's row, as "FSKit Modules", not under a separate "File System Extensions" item.
- `mount` reports "Module … is disabled!" until the user enables it. **The System Settings switch cannot enable it**: clicking does not move the switch, even with the app moved to `/Applications` and System Settings quit and reopened. `pluginkit -e use` marks the extension, but FSKit still reports it disabled.
- FSKit keeps the list of enabled modules in `~/Library/Group Containers/group.com.apple.fskit.settings/enabledModules.plist`; the switch never writes to it.
- Gatekeeper rejects the Development-signed build (`spctl --assess`: rejected). To rule out signing, the spike was signed with **Developer ID** (Xcode creates a cloud-managed certificate when exporting with `developer-id`), **notarized** (Accepted), stapled and installed in `/Applications`; Gatekeeper accepts it ("Notarized Developer ID"). **The switch still does not work**, so signing is not the cause.
- Adding the module id to `enabledModules.plist` by hand does not take effect at once: `fskit_agent` keeps the state in memory and cannot be restarted (it ignores SIGTERM, and `launchctl kickstart -k user/<uid>/com.apple.fskit.fskit_agent` reports "Operation not permitted while System Integrity Protection is engaged").

**After a restart (15 November 2026): it mounts.** `fskit_agent` reread `enabledModules.plist`, and `mount -F -t droidspike 'droidspike://test?files=10000' /tmp/droidspike` worked: `mount` lists `droidspike://test?files=10000 on /private/tmp/droidspike (droidspike, nodev, nosuid, noowners, noatime, fskit, mounted by <user>)`. `hello.txt` reads back correctly.

**Measurements** (`/usr/bin/time`; the extension serves data from memory, no phone behind it):

| Task | FSKit | File Provider (same Mac, emulator) |
|---|---|---|
| List 10,000 names (`ls -f`) | 0.11 seconds | 401 seconds the first time (fileproviderd creating placeholders) |
| List 10,000 entries with attributes (`ls -l`) | 1.68 seconds (3.8 the first time) | as above |
| `stat` one file, read a small file | 0.01 seconds | |
| Extension memory | 9 MB | 16–17 MB |

So File Provider's slow part (about 30 ms per entry) does not exist with FSKit: what remains is the real time to fetch the listing from the phone, about 1.6 seconds for 10,000 entries over ADB (S0-b).

**Why the switch does not work.** It is a macOS 26.x bug, documented in detail in [MacFabric/iSCSI-NVMe-TCP, `docs/feedback-fskit-enablement-26x.md`](https://github.com/MacFabric/iSCSI-NVMe-TCP/blob/main/docs/feedback-fskit-enablement-26x.md): a notarized Developer ID module cannot be enabled on 26.6.1, while the identical build enables on the first click on macOS 27.0. It reproduces with Apple's own `FSKitSample` on 26.1 and 26.2. On each click `fskitd` logs "Received error '(null)', errno 2, retrieving team ID". On macOS 26 there is also no way to send the user to the right settings page: `FSClient.openFileSystemExtensionsSettings()` exists only from macOS 27. The only workaround is adding the id to `enabledModules.plist` and restarting `fskitd` (or logging in again), which an app should not do itself.

**How an app could mount an FSKit volume (tested 15 November 2026).**

- `FSClient` only lists modules (`installedExtensions`, with `isEnabled`); it cannot enable a module or mount. On the test Mac it did not even list the spike module, although `mount -F` used it.
- `NetFSMountURLAsync` (the route Finder's "Connect to Server" takes) does not hand unknown schemes to FSKit: Finder reports "URLs with the type droidspike: are not supported".
- `/sbin/mount -F -t droidspike <url> <folder>` works from an **unsandboxed** process; from a **sandboxed** app it reports "Unable to invoke task". DroidDrive.app is sandboxed, so an FSKit mode would need an unsandboxed helper (for example a launch agent registered with `SMAppService.agent`) to mount. That helper could also vend a Mach service named with the app group prefix, through which the (sandboxed) FSKit extension reaches the app for phone data.

**Conclusion.** Yes: FSKit on macOS 26 mounts a URL-backed file system without a block device, and lists large folders hundreds of times faster than File Provider. It was **not adopted** (decided 15 November 2026): on macOS 26 a third-party module can only be enabled by hand, an FSKit mount behaves differently from File Provider (no offline copies, no offline edit queue for FR-10, no status badges, the drive must be unmounted when the phone goes away), and DroidDrive is for personal use, where File Provider is enough.

## S0-a

No conclusion yet. The tools are ready (see above). S0-a needs a real phone on USB in "File transfer" mode, ideally both a Pixel and a Samsung (plan section 1).
