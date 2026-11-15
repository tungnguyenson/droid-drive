# DroidDrive implementation plan

This is the plan for building DroidDrive, the macOS app that mounts Android phones in Finder described in [`spec.md`](spec.md). The spec answers "what to build"; this plan answers "in which order, what each step contains, when it is done, and what to prepare first".

Status on the evening of 14 November 2026: code exists for the first four phases. Everything that runs without a phone on a cable has been tested with the Android Emulator and with a real Pixel 4 XL (Android 13) over Wi-Fi. USB and MTP have only run against an in-memory fake phone, since no real phone has been plugged in yet; DroidDrive's own Wi-Fi pairing has been tested with the emulator, with the real `adb pair`, and with the Pixel (QR code). Spike results are in [`spikes.md`](spikes.md).

The **Done** column in the task tables: ✅ means the "Done when" criterion is met (on the emulator when the criterion does not require a real phone), ◐ means partly done, blank means not started. What each task still lacks is listed in section 5.

How the work is split: highest risk first. Phase 0 is four small spikes, each answering a yes/no question that would change the design if the answer were wrong. After that, each phase produces a build that works on real hardware and is done when its functional requirements (the `FR-xx` ids in section 4 of the spec) pass.

## 1. What to prepare before starting

1. **A paid Apple Developer account (USD 99/year).**
   Recommendation: use an existing one; no separate team is needed. App groups, Developer ID and notarization all need a paid account; the File Provider extension runs with development signing, but cannot be distributed that way.
   Otherwise: phases 0 and 1 still work with development signing; only phase 4 (notarization) is blocked.
2. **Test devices.**
   Recommendation: at least one Pixel (Android 15 or 16) and one Samsung (Android 14 or later) before phase 1; an Android 10 or earlier phone before phase 3 (for `tcpip`); a Kindle or GoPro is optional in phase 2.
   With a single phone: workable, but One UI (Samsung) specific bugs will only show up when someone else uses it.
3. **Test Macs.**
   Recommendation: the main Mac on macOS 26; a macOS 13 virtual machine (UTM or Parallels on Apple silicon) to check the minimum version. Virtual machines do not pass USB through reliably, so test only ADB over Wi-Fi there.
4. **Tools:** the latest Xcode, Android Studio (for the emulator and `adb` as the speed baseline), OpenMTP (the MTP speed baseline).

## 2. Repository layout

Code is split into Swift packages by layer, so each layer can be tested without the app or the extension. The app and the extension are thin shells that call into the packages.

In practice the layers became **one** Swift package, `Packages/`, with one target per layer (instead of one package per layer), so a single `swift test` runs every layer's tests. The Xcode project is generated from `project.yml` with XcodeGen and is not committed.

```
android-mac-transfer/
├── docs/                    spec.md, plan.md, spikes.md
├── project.yml              XcodeGen → DroidDrive.xcodeproj (git-ignored)
├── Config/Signing.xcconfig  team and bundle id prefix; override in Signing.local.xcconfig
├── App/                     menu-bar app target (SwiftUI)
├── FileProvider/            NSFileProviderReplicatedExtension target
├── Shared/                  code shared by app and extension (app group)
├── Packages/
│   ├── Package.swift
│   ├── Sources/
│   │   ├── DroidCore/       DeviceTransport, RemoteEntry, errors, name normalization, DomainIdentifier, FakeTransport
│   │   ├── ItemStore/       SQLite: identifier ↔ path, versions, generations + tombstones
│   │   ├── AdbKit/          ADB packets, AUTH, sync, shell, TCP / adb server / TLS links, AdbTransport, key store
│   │   ├── UsbKit/          IOUSBHost: device watching, interfaces, pipes, holder detection
│   │   ├── MtpKit/          PTP/MTP session and MtpTransport
│   │   ├── AdbPairing/      SPAKE2 + TLS pairing, mDNS, QR, reconnects, the Wi-Fi sheet
│   │   ├── CSpake2/         SPAKE2 over Curve25519 from BoringSSL
│   │   ├── DeviceService/   device sources and registry, XPC link, transfer log
│   │   └── DroidDrive*CLI/  droiddrive-cli, droiddrive-usb, droiddrive-wifi: test and benchmark tools, not shipped in the app
│   └── Tests/               unit tests per layer, IntegrationTests (need a device), fixtures
├── spikes/fskit/            throwaway FSKit module from spike S0-d
└── Tests/fixtures/          malicious-names.bin (malicious file names, NUL-separated)
```

## 3. Phases

The estimates are rough, for one person full time, mainly to show the relative size of the phases. About 11 to 13 weeks in total.

| Phase | Content | Estimate | Progress (14–15 November 2026) |
|---|---|---|---|
| 0 | Four spikes | 1 week | 2/4 ✅, 1 ◐ |
| 1 | MVP over ADB + USB | 3 weeks | 6/14 ✅, 8 ◐ |
| 2 | MTP | 3 weeks | 0/9 ✅, 8 ◐ (fake phone only) |
| 3 | Wi-Fi | 2–3 weeks | 5/8 ✅, 3 ◐ |
| 4 | Finishing and release | 2 weeks | 4/8 ✅, 4 ◐ |
| 5 | Optional (Shortcuts, App Store) | not estimated | |

### Phase 0: four spikes

Each spike is a small throwaway program; only its conclusion is kept. Results go in `docs/spikes.md`: the question, how it was tested, machine and versions, the result, and what it means for the design.

| Id | Done | Question | How | If "no" |
|---|:-:|---|---|---|
| S0-a |  | Can `IOUSBHost` open a phone's MTP interface on macOS 26 while `ptpcamerad` runs? After stopping `ptpcamerad`, does it grab the device again? | Swift CLI: find the MTP interface, open it exclusively, send `GetDeviceInfo`, `OpenSession`. Repeat after `killall ptpcamerad`. Try on a Pixel and a Samsung | Try `libmtp` + `libusb`; if that fails too, MTP is "experimental" in the first release and spec section 5.7 is updated |
| S0-b | ◐ | Can we write our own ADB handshake over USB up to `sync:` `LIST`? | Swift CLI: find the ADB interface, `CNXN`, `AUTH` (generate an RSA key, sign the token), open `sync:`, list `/sdcard` | No good alternative; this one must pass. If stuck for more than 3 days, consider bundling `adb` (decision 4 reopens) |
| S0-c | ✅ | Does a replicated File Provider with fake data show in Finder, read, write and rename, and does a simulated disconnect queue operations? | Minimal app + extension, in-memory fake transport, talking over an app-group XPC Mach service | No alternative within the agreed scope; write down the limits found and ask the user |
| S0-d | ✅ | Can FSKit on macOS 26 mount a file system not backed by a block device? | Read the latest FSKit docs, build an `FSUnaryFileSystem` extension from FSKitSample, try mounting a URL or path resource | Drop FSKit from phase 5 and record why |

Done when: `docs/spikes.md` has a conclusion for all four, and the spec is updated wherever a conclusion changes the design.

### Phase 1: MVP over ADB and USB

Goal: plug in a phone with USB debugging on, the phone shows in Finder, every file operation works.

| Id | Done | Task | Depends on | Done when |
|---|:-:|---|---|---|
| P1-01 | ◐ | Xcode project, two targets, app group, entitlements (spec section 8), empty packages, CI build + test | | CI green on an empty commit |
| P1-02 | ✅ | `DroidCore`: `DeviceTransport`, `RemoteEntry`, error enum, NFC normalization, forbidden-character checks, `FakeTransport` | P1-01 | Unit tests for normalization and forbidden characters |
| P1-03 | ◐ | `UsbKit`: plug/unplug watching, opening interfaces, bulk pipes, async I/O, finding the holding process | P1-01 | The CLI prints devices and interfaces as they are plugged and unplugged |
| P1-04 | ✅ | `AdbKit` packets: encode, decode, checksum, stream reader | P1-02 | Unit tests with sample packets taken from real `adb` (Wireshark or adb's log) |
| P1-05 | ◐ | `AdbKit` authentication: RSA-2048 generation, Keychain storage, token signing, Android public-key format | P1-04 | The phone shows the allow dialog; it does not ask again next time |
| P1-06 | ◐ | `AdbKit` sync: `LIS2`/`LIST`, `STA2`/`STAT`, `RCV2`/`RECV`, `SND2`/`SEND` with mtime | P1-05 | Push and pull a 6 GB file, SHA-256 matches |
| P1-07 | ✅ | `AdbKit` shell: `shell,v2` with exit codes, safe path quoting, `mkdir`, `rm`, `mv`, `df`, listing `/storage` | P1-05 | Unit tests with the malicious-names set in `Tests/fixtures`; no name runs as a command |
| P1-08 | ✅ | `AdbKit` through the adb server: detect port 5037, `host:transport:<serial>`, then the same sync and shell | P1-06 | With Android Studio already open, DroidDrive still mounts the phone |
| P1-09 | ◐ | `AdbTransport`: `DeviceTransport` on top of `AdbKit`, batched listing, 4 parallel streams | P1-06, P1-07 | Integration tests with the Android Emulator over TCP run on CI |
| P1-10 | ✅ | `ItemStore`: SQLite schema, stable UUIDs, renames keep identifiers, versions, conflicts | P1-02 | Unit tests for rename, move, conflict |
| P1-11 | ✅ | `DeviceService`: device manager, sessions, XPC server, file descriptor passing | P1-09 | A fake extension lists a folder over XPC |
| P1-12 | ◐ | File Provider extension: one domain per storage, paged enumeration, fetch, create, modify, delete, disconnects | P1-10, P1-11 | FR-03 to FR-10 pass with the emulator |
| P1-13 | ◐ | Menu-bar app: device list, Open in Finder, Mount/Unmount, USB debugging guidance, open at login | P1-11 | FR-01, FR-19 pass |
| P1-14 | ◐ | Run the phase's FR table on a real Pixel and Samsung, fix bugs | P1-12, P1-13 | FR-01, FR-03 to FR-10, FR-19 pass on both |

### Phase 2: MTP

Goal: a phone without USB debugging still works, and a 10,000-file folder lists completely.

| Id | Done | Task | Depends on | Done when |
|---|:-:|---|---|---|
| P2-01 | ◐ | `MtpKit` containers: 12-byte header, data, response, event; PTP data types (UTF-16 strings, arrays) | P1-03 | Unit tests with sample packets captured from OpenMTP |
| P2-02 | ◐ | `MtpKit` session: `GetDeviceInfo`, `OpenSession`, supported operations, one operation at a time | P2-01 | The CLI prints device and storage info |
| P2-03 | ◐ | Listing with `GetObjectPropList`, falling back to `GetObjectHandles` + `GetObjectInfo` | P2-02 | A 10,000-file folder lists completely, timed per spec section 9 |
| P2-04 | ◐ | Read (`GetPartialObject64`, falling back to `GetObject`), write (`SendObjectInfo` + `SendObject`, files ≥ 4 GB), edit (Android extension operations, with a fallback) | P2-02 | A 6 GB file there and back, SHA-256 matches |
| P2-05 | ◐ | Create folder, delete, rename, move (falling back to copy then delete) | P2-02 | Each operation is visible in the Files app on the phone |
| P2-06 | ◐ | Events from the interrupt endpoint → `ChangeHint` → `signalEnumerator` | P2-02, P1-12 | A new photo shows in Finder without waiting for the refresh interval (FR-11) |
| P2-07 | ◐ | `MtpTransport` and MTP/ADB choice per device, remembered | P2-03 to P2-05 | FR-02 passes |
| P2-08 | ◐ | Busy device: find the holder, status and per-app advice, automatic retry, per the S0-a conclusion | P2-02 | FR-16 passes with `ptpcamerad` and with OpenMTP open |
| P2-09 |  | Run the FR table on a Pixel, a Samsung, and a Kindle or GoPro if available | P2-07, P2-08 | FR-02, FR-11, FR-16 pass; FR-04 to FR-08 also pass over MTP |

### Phase 3: Wi-Fi

| Id | Done | Task | Depends on | Done when |
|---|:-:|---|---|---|
| P3-01 | ◐ | Plain ADB over TCP: `tcpip:5555` over USB, read the IP, connect, remember the device | P1-09 | FR-14 passes on an Android 10 phone |
| P3-02 | ✅ | `AdbPairing`: SPAKE2 C module from BoringSSL, checked against AOSP `pairing_auth` | | Unit tests with vectors produced by the real `adb pair` |
| P3-03 | ✅ | Pairing over TLS: certificate exchange, storing the device certificate | P3-02 | Pairing with a 6-digit code succeeds with a Pixel |
| P3-04 | ✅ | mDNS: browse `_adb-tls-pairing._tcp` and `_adb-tls-connect._tcp` with `NWBrowser`, local network permission | P1-01 | Phones waiting to pair appear in the sheet |
| P3-05 | ✅ | TLS connection after pairing: `CNXN` → `STLS` → TLS 1.3 with the RSA key's certificate | P3-03 | A drive mounts over Wi-Fi, FR-06 passes over Wi-Fi |
| P3-06 | ✅ | QR code: generate service name and password, draw the QR code, wait for the phone's advertisement, then pair | P3-03, P3-04 | FR-12 passes |
| P3-07 | ◐ | Connect via Wi-Fi sheet with four tabs, manual IP:port:code | P3-05 | FR-13 passes |
| P3-08 | ◐ | Reconnect automatically when a paired device shows up | P3-05 | FR-15 passes |

### Phase 4: finishing and release

| Id | Done | Task | Done when |
|---|:-:|---|---|
| P4-01 | ◐ | Full Devices window (spec section 6), illustrated guidance for "File transfer" and USB debugging | Someone who has never used it mounts a phone without asking |
| P4-02 | ✅ | Transfer log: kept 7 days, filters, speeds | FR-17 passes |
| P4-03 | ✅ | File status in Finder, decorations where needed | FR-18 passes |
| P4-04 | ✅ | Settings (spec section 7), per-device refresh interval, Remove Device | FR-20 passes |
| P4-05 | ✅ | English-only UI (changed 14 November 2026; previously Vietnamese and English) | No Vietnamese left in the UI, drive names, conflict-copy names or error messages |
| P4-06 | ◐ | Measure performance per spec section 9, fix what misses | Numbers recorded in `docs/spikes.md` |
| P4-07 | ◐ | Developer ID signing, notarization, update feed, download page | A notarized build installs on a clean Mac |
| P4-08 | ◐ | Run all of FR-01 to FR-20 on the device matrix and macOS 13, 15, 26 | No data-loss bugs left; the remaining ones are in the release notes |

### Phase 5: optional

Planned in detail only when phase 4 is done and the user chooses: App Intents for Shortcuts, Mac App Store, paid tier. FSKit was evaluated in spike S0-d and not adopted (see section 5).

## 4. How each task is done

- Tests first for packets, ItemStore, name normalization and path quoting; at least 80% coverage for the packages in `Packages/`.
- One branch and one pull request per task, named after the task id (`p1-06-adb-sync`).
- Every write or delete on the phone needs a conflict test before it is merged.
- When a finding differs from the spec, update the spec in the same pull request.

## 5. Progress

Status per task is kept here and in pull requests.

Status on 14–15 November 2026. "Emulator" is the Android Emulator (Android 15); "Pixel" is a real Pixel 4 XL (Android 13) over Wi-Fi; "fake phone" is the in-memory MTP device of the test suite.

| Id | Done so far | Still missing |
|---|---|---|
| S0-a | The `droiddrive-usb` tool (`list`, `mtp-info`, `mtp-ls`, `mtp-pull`, `adb-info`) | Run with a Pixel and a Samsung on a cable, before and after `killall ptpcamerad` |
| S0-b | Passes over TCP and through the adb server; ADB over USB runs against a fake USB pipe | Run over real USB |
| S0-c | Passes | |
| S0-d | Yes: FSKit mounts from a URL and lists 10,000 entries in 0.11 seconds against 401 seconds through File Provider (see `spikes.md`) | Decided 15 November 2026: **no FSKit mode**. DroidDrive is for personal use, File Provider is enough; on macOS 26 an FSKit module can only be enabled by hand |
| P1-01 | Project, two targets, app group, entitlements; `.github/workflows/ci.yml` (package tests, unsigned app build) | Run CI on GitHub |
| P1-02 | Done | |
| P1-03 | `UsbKit`: plug/unplug watching, interface detection, holder detection, `UsbPacketLink`; the app has an ADB-over-USB source used when no adb server runs | Open a real USB interface for the first time |
| P1-04 | Done | |
| P1-05 | Key in the Keychain (`AdbKeyStore`), shared by the app and the CLI | See the "Allow" dialog on a real phone when DroidDrive connects over USB itself |
| P1-06 | 1 GB on the emulator, 300 MB on the Pixel over Wi-Fi, SHA-256 matches | 6 GB file |
| P1-07 | Done | |
| P1-08 | Done; drives are named after `ro.serialno` | |
| P1-09 | Integration tests pass on the emulator and the Pixel (`DROIDDRIVE_TEST_ROOT`) | Run on CI |
| P1-10 | Done | |
| P1-11 | The app holds the connections, the extension calls it over XPC (File Provider service + Darwin notification, see spec 5.1); works when the app quits and starts again | |
| P1-12 | FR-03 → 06, 08 → 11 pass on the emulator; on the Pixel: create, rename, move, edit, delete, Vietnamese names, conflicts | FR-07 (6 GB) |
| P1-13 | Menu, Devices window, mounting storages that appear later (SD card), FR-19 | FR-01 over real USB |
| P1-14 | Pixel over Wi-Fi (adb server, then DroidDrive's own connection): 7/8 integration tests pass, speed ≥ 80% of `adb` | Pixel over USB, a Samsung; first page of a 10,000-file folder measured at 2.27 seconds (target 2) while sharing bandwidth, to be measured again alone |
| P2-01 → P2-08 | `MtpKit` and `MtpTransport` pass the same checks as ADB; the app has an MTP source; recognizes `ptpcamerad`, Android File Transfer, OpenMTP, MacDroid… with advice | Everything on a real phone; sample packets captured from OpenMTP; per-device MTP/ADB choice beyond the global setting |
| P2-09 | | Needs a real phone |
| P3-01 | `TcpipSwitch`, the "Android 10 and earlier" tab | Run with an Android ≤ 10 phone |
| P3-02 | Done, checked against a reference model and the real `adb pair` | |
| P3-03 | Paired with the real Pixel by QR code (14 November 2026); 6-digit code with the emulator; the real `adb pair` pairs with DroidDrive's `PairingServer` | 6-digit code with a real phone |
| P3-04 | Done; sees the real Pixel over mDNS | |
| P3-05 | The Pixel mounts over DroidDrive's own TLS connection (no adb server): listing, create, rename, edit, 20 MB upload (1.8 MB/s), delete through Finder | A phone rejecting an unknown key |
| P3-06, P3-07 | "Connect via Wi-Fi…" window with four tabs, in the menu; the real Pixel paired by QR code (FR-12) | 6-digit code and manual IP:port:code on a real phone (FR-13) |
| P3-08 | `WifiReconnector` inside the app's Wi-Fi source | FR-15 on a real phone |
| P4-01 | Devices window, guidance in text and SF Symbols | A new user trying it; illustrated guidance |
| P4-02 | Done (FR-17) | |
| P4-03 | Badge on "(Mac copy)" files (FR-18) | |
| P4-04 | Settings, per-device refresh, Remove Device removes drives, cache and Wi-Fi pairing (FR-20) | "Generate new ADB key" button |
| P4-05 | English-only UI | |
| P4-06 | Numbers in `spikes.md` | Listing large folders through Finder misses section 9: fileproviderd spends about 30 ms per entry |
| P4-07 | `scripts/release.sh` (archive, Developer ID signing, notarization, stapling, DMG) | Low priority for personal use; update feed and hosting undecided |
| P4-08 | FR table on the emulator | Real device matrix, macOS 13 and 15 |
