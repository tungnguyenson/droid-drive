# Specification: mounting Android phones in the Mac Finder

This is the specification for rebuilding an app equivalent to [MacDroid](https://www.macdroid.app/): a macOS app that mounts an Android phone as a drive in Finder, so you can browse, open, edit and copy files both ways as with any USB drive. It is needed because macOS cannot read an Android phone over a cable (Android speaks MTP, the Mac only understands the cameras' PTP), and Google's Android File Transfer is no longer maintained.

Goal: a reader (a developer, or an agent) knows what to build, in which order, and when each part is done. Section 2 records what MacDroid does (researched on 13 November 2026). The remaining sections specify the rebuild, working name **DroidDrive**.

The approach in short: a Swift menu-bar app holds the connection to the phone over two routes (MTP over USB, ADB over USB or Wi-Fi) and puts the files in Finder with File Provider, Apple's official mechanism for cloud drives (iCloud Drive, Dropbox and Google Drive all use it). The constraint that shapes the design: no kernel extension and no macFUSE, so users do not have to install anything else or lower their Mac's security.

## 1. Terms

| Term | Meaning |
|---|---|
| MTP (Media Transfer Protocol) | The USB file transfer protocol Android turns on when the user picks "File transfer" on the phone. Nothing else needs enabling. An extension of PTP. |
| PTP (Picture Transfer Protocol) | The original protocol for cameras. MTP is PTP plus commands for file properties. |
| ADB (Android Debug Bridge) | Android's debugging protocol. Needs "USB debugging" in Developer options. Reads and writes files faster than MTP and reaches the system folders the shell user can read. |
| Wireless debugging | ADB over Wi-Fi, available since Android 11. The first time, the Mac pairs with a QR code or a 6-digit code. |
| File Provider | Apple's framework for an app to put a "remote" file tree in Finder. The files live under `~/Library/CloudStorage/` and show under Locations in the Finder sidebar. MacDroid calls this mount type "macOS Native Drive". |
| Domain (File Provider) | One "drive" in Finder. DroidDrive creates one domain per storage of each device (internal storage, SD card). |
| FSKit | Apple's framework (macOS 15.4 and later) for user-space file systems, replacing kernel extensions and macFUSE. |
| macFUSE | A third-party library for writing file systems; needs a kernel extension or the FSKit backend. DroidDrive does not use it. |
| Transport | The layer that talks to the phone (MTP or ADB). The layers above see one interface: list, read, write, delete, rename. |
| Helper | DroidDrive's background process that holds the connection to the phone. Here it is the menu-bar app itself. |
| `ptpcamerad` | The macOS system process that grabs camera-like devices when they are plugged in. The most common reason Mac MTP tools "cannot see the phone". |

## 2. What MacDroid does (research)

Sources: MacDroid's home page, pricing page, FAQ and version history (links in section 14). Latest version at the time of reading: 2.10.1206, released 30 June 2026, by Electronic Team, Inc.

### 2.1 Features and tiers

| | Free | PRO |
|---|---|---|
| Copy files from the phone to the Mac, view files on the phone | Yes | Yes |
| Copy files from the Mac to the phone | No | Yes |
| Edit files directly on the phone without copying them back | No | Yes |
| USB and Wi-Fi | (the pricing page lists it under PRO only) | Yes |
| Other MTP devices: GoPro, Kindle, Garmin, Nintendo Switch, Oculus, Sony Walkman, Onyx Boox | | Yes |
| Price | 0 | USD 34 lifetime (struck-through 49), or USD 19 per year with a 7-day trial |

One PRO licence covers up to 5 Macs and any number of phones. Sold through Paddle and on the Mac App Store (the App Store build has no macFUSE mount type).

### 2.2 Three ways to connect

- **MTP**: plug in the cable and choose "File transfer" on the phone. Works with non-Android devices too. The FAQ admits two problems: folders with very many files can show up empty (the only fix offered is switching to ADB), and it cannot connect while another app holds the device (iPhoto, for example).
- **ADB**: turn on USB debugging and tap "Allow" on the phone (optionally ticking "Always allow from this computer"). Advertised as "smoother and faster", and it reaches system folders.
- **Wi-Fi**: still ADB, over the network. Android 11 and later pair with a QR code, a 6-digit code, or IP + port + code typed in by hand. Android 10 and earlier take an IP. A third option: plug in USB once and MacDroid switches to Wi-Fi by itself. The Mac and the phone must be on the same Wi-Fi network.

### 2.3 Three mount types

| Type | How MacDroid describes it | Mechanism (my inference; the pages do not say) |
|---|---|---|
| macOS Native Drive (recommended) | "the native macOS way of mounting cloud drives", since macOS 11.3, works offline, changes upload when the connection returns | File Provider, replicated |
| macFUSE Drive | needs macFUSE installed | macFUSE |
| Network Drive | nothing to install, but under many simultaneous operations listings load slowly or the drive drops | a WebDAV or SMB server on the Mac, mounted by Finder as a network drive |

### 2.4 UI and settings

- A menu-bar icon, a device list window, Mount/Unmount per device, a "Connect via Wi-Fi" button.
- An Activity Log window with transfers and speeds (added in 2.5 and 2.8).
- Finder shows status badges on files: downloading, uploading, waiting to upload, error (usually out of space on the phone or the Mac, or a dropped connection).
- General settings: open at login, mount automatically when the app opens, show drives on the desktop, short names in the Finder sidebar, cache folder (macOS 15+), how long to keep cached files, drag-and-drop copies instead of moving, let other accounts on the Mac see the drives (needs FUSE). Some items are hidden until you hold Option.
- Per-device settings: content refresh interval, mount type (hidden), remove device.
- AppleScript support (since 1.3), Apple silicon (since 1.4).

### 2.5 MacDroid weaknesses the rebuild should do better

1. Large folders over MTP do not show. Likely cause: listing one file at a time (`GetObjectInfo` per file) instead of in batches. See 5.3.
2. When another app holds the device, the message is generic. The rebuild should say which process holds it and how to free it. See 5.7.
3. File-name encoding errors with rsync. With Vietnamese (or any accented) file names, Unicode normalization is mandatory. See 5.6.
4. Three mount types with three different feature sets; many settings apply to only one type. The rebuild has a single type.

## 3. Scope

### 3.1 In scope

- Mount a phone's internal storage and SD card in Finder, read and write.
- Connect over MTP (USB), ADB (USB), ADB over Wi-Fi (Android 11+ pairing, Android 10 and earlier through `tcpip`).
- Work offline with files already downloaded; changes upload when the connection returns.
- Menu bar, device window, transfer log window, settings.
- Non-Android MTP devices (Kindle, GoPro…) at the level of "works if the device follows the MTP standard", with no per-model commitment.

### 3.2 Out of scope (first release)

- macFUSE, kernel extensions, the network-drive type.
- Free/PRO tiers and payments.
- Root, reading system partitions beyond the ADB shell's permissions.
- Backups, scheduled two-way sync, screen mirroring, messages.
- Windows, Linux.

## 4. Functional requirements

Each requirement has acceptance criteria that can be checked by hand or by a test.

| Id | Requirement | Acceptance |
|---|---|---|
| FR-01 | Detect a device when the cable is plugged in | The device shows in the menu within 2 seconds after the phone is in "File transfer" mode or has allowed ADB |
| FR-02 | Choose MTP or ADB per device and remember the choice | Unplug and replug: the mode stays. If both are available, ADB is the default (faster, fewer bugs) |
| FR-03 | Mount each storage as a drive in Finder | Internal storage and SD card show as two sidebar items, named like "Pixel 8 · Internal storage" (SD card: "Pixel 8 · SD card 1A2B-3C4D") |
| FR-04 | Browse folders | A 10,000-file folder lists completely over both MTP and ADB (compared with `adb shell ls \| wc -l`) |
| FR-05 | Open files from Finder | Double-clicking a photo, PDF or video opens it in the default app; the file downloads on open |
| FR-06 | Copy, edit, create, delete, rename and move files and folders | Every operation done in Finder is visible on the phone (Google's Files app) once the file no longer shows "uploading" |
| FR-07 | Files larger than 4 GB | A 6 GB video copied there and back has a matching SHA-256 |
| FR-08 | Unicode file names | A file named "Ảnh cưới Đà Lạt.jpg" created on the Mac shows correctly on the phone and vice versa; no two files differing only in normalization form |
| FR-09 | Keep modification times | After copying a file to the phone over ADB, `stat` on the phone shows the original mtime. MTP: note it if the device does not support it |
| FR-10 | Work offline | Unplug the cable: downloaded files still open; edit a file, plug back in, the edit uploads within 10 seconds |
| FR-11 | See changes made on the phone | Take a new photo: it shows in Finder within the refresh interval (30 seconds by default; immediately with MTP events) |
| FR-12 | Wi-Fi on Android 11+ with a QR code | Scan the QR code under Wireless debugging; the device appears in the list without typing anything |
| FR-13 | Wi-Fi with a 6-digit code, or IP:port typed by hand | As above |
| FR-14 | Wi-Fi on Android 10 and earlier | Plug in USB once, turn on "Switch to Wi-Fi", unplug: the drive stays mounted |
| FR-15 | Reconnect paired Wi-Fi devices automatically | Turn the phone's Wi-Fi off and on: the device reconnects on the same network without pairing again |
| FR-16 | Report a device held by another process | When `ptpcamerad` or another process holds the device, the status names the process and offers a how-to-fix button (5.7) |
| FR-17 | Transfer log | A window lists each transfer: time, file, direction, size, speed, result; filter by device and status |
| FR-18 | File status in Finder | Downloading, uploading, waiting and failed files have different badges |
| FR-19 | Unmount | Unmount removes the domain from Finder; a running transfer asks for confirmation before it is cancelled |
| FR-20 | Remove a device | Removes the device's domains, cache and Wi-Fi pairing keys |

## 5. Architecture

### 5.1 Processes

```
┌──────────────── DroidDrive.app (menu bar, opens at login) ───────────────────┐
│ UI (SwiftUI)        DeviceManager            TransferQueue / ActivityLog       │
│                      ├─ UsbWatcher (IOKit)                                     │
│                      ├─ WifiDiscovery (mDNS)                                    │
│                      └─ DeviceSession × N ── Transport: MtpTransport            │
│                                                       │ AdbTransport (USB/TCP) │
│ ExtensionLinker: connects to each domain's service ◄────────────────────────┐  │
└────────────────────────────────────────────────────────────────────────────│──┘
                                                                             │ XPC
┌──────────── DroidDriveFileProvider.appex (started by macOS) ───────────────┴──┐
│ NSFileProviderReplicatedExtension, one instance per domain                     │
│ ItemStore (SQLite in the app group): identifier ↔ path, metadata              │
└────────────────────────────────────────────────────────────────────────────────┘
```

Why the main app holds the connection instead of the extension: only one process can claim a USB interface at a time, and macOS can stop the extension at any moment. One place owns the session; the extension is a guest.

**How the XPC link works (built 14 November 2026).** The original design was a Mach service in the app group, opened by the app. That does not work: a process launchd did not start cannot register a Mach service (`NSXPCListener(machServiceName:)` reports "lookup error 3", and the sandboxed test build crashed at launch). So the connection runs the other way:

- The extension vends an `NSFileProviderServiceSource` per domain, which only accepts processes allowed to manage that domain. Behind it is an anonymous `NSXPCListener` that checks the code signature of the connecting process (same bundle id and team).
- The app connects with `NSFileProviderManager.service(named:for:)` and exports a `DeviceHost` limited to that domain's storage (every path is checked against the storage root, `..` is rejected, the root cannot be deleted or renamed).
- When the extension needs the phone and has no connection, it posts a per-domain Darwin notification and waits up to 4 seconds for the app to connect.
- If the app is not running, every call reports `disconnected` (which becomes `serverUnreachable`), and for the next 10 seconds fails immediately instead of waiting again. A quit app therefore behaves like a pulled cable: Finder keeps the changes and uploads them when the app runs again (measured: 2 seconds after relaunch).
- Linking takes 20–130 ms. macOS runs one extension process per domain and restarts them about every 30 seconds.

Code: `Packages/Sources/DeviceService/` (`XPCProtocols`, `DeviceHost`, `HostLink`, `RemoteDeviceTransport`, `DeviceRegistry`, `DeviceSource`), `App/ExtensionLinker.swift`, `App/DeviceSources.swift`. Each way of finding phones (adb server, ADB over USB, MTP, Wi-Fi) is a `DeviceSource`; `DeviceRegistry` merges them by `ro.serialno` and picks the best connection (ADB-USB, then ADB-Wi-Fi, then MTP, or MTP first if the user prefers it).

If the app is not running, the extension returns `NSFileProviderError.serverUnreachable`; Finder queues the changes and retries later. That is why "Open at login" is on by default, registered with `SMAppService.mainApp`.

Data between the extension and the app: the extension creates a temporary file in `NSFileProviderManager.temporaryDirectoryURL()` and sends its file descriptor over XPC; the app writes straight into it (or reads from it for uploads). No file bytes go through XPC messages. Directory listings are pulled in batches of 500 entries; progress and cancellation travel over the same connection.

### 5.2 Common transport interface

Every layer above knows only this interface. MTP and ADB each implement it; tests use an in-memory fake.

```swift
protocol DeviceTransport: Sendable {
    var info: DeviceInfo { get }                       // manufacturer, model, serial, Android version
    func storages() async throws -> [StorageInfo]      // id, name, capacity, free space
    func list(_ dir: RemotePath) -> AsyncThrowingStream<[RemoteEntry], Error>  // in batches
    func stat(_ path: RemotePath) async throws -> RemoteEntry
    func read(_ path: RemotePath, to fd: FileHandle, range: Range<UInt64>?,
              progress: Progress) async throws
    func write(_ path: RemotePath, from fd: FileHandle, mtime: Date?,
               progress: Progress) async throws -> RemoteEntry
    func mkdir(_ path: RemotePath) async throws -> RemoteEntry
    func delete(_ path: RemotePath, recursive: Bool) async throws
    func rename(_ from: RemotePath, to: RemotePath) async throws -> RemoteEntry
    var changes: AsyncStream<ChangeHint> { get }       // MTP has events; ADB is empty and relies on periodic refresh
}
```

`RemoteEntry` holds the name, path, kind (file, folder, symlink), `UInt64` size, mtime, and a transport-private key (the MTP handle). Every error maps to one enum: `disconnected`, `busy(by: String?)`, `notFound`, `exists`, `noSpace`, `permissionDenied`, `unsupported`, `invalidName(String, reason:)` (a name that breaks 5.6, with a reason to show the user), `protocolError(String)`.

A session runs one MTP operation at a time (MTP has no concurrency). ADB allows many streams on one connection; transfers are capped at 4 at once per device.

### 5.3 MTP

**Finding devices.** Plug and unplug are watched with `IOServiceAddMatchingNotification`. A USB interface is MTP if it is class 0x06, subclass 0x01, protocol 0x01; or class 0xFF with the interface string "MTP" (Android with MTP and ADB both on). Each interface has three endpoints: bulk in, bulk out, interrupt in (events).

**USB access.** `IOUSBHost` (`IOUSBHostInterface`, `IOUSBHostPipe`), opening the interface exclusively. `kIOReturnExclusiveAccess` means another process holds it (5.7).

**Container format.** Every packet has a 12-byte little-endian header: length (`UInt32`), type (`UInt16`: 1 command, 2 data, 3 response, 4 event), code (`UInt16`), transaction id (`UInt32`), then up to 5 `UInt32` parameters.

**Operations used:**

| Task | Operation | Notes |
|---|---|---|
| Open a session | `GetDeviceInfo` 0x1001, `OpenSession` 0x1002 | `DeviceInfo` lists the operations the device supports; check before using an extension operation |
| Storages | `GetStorageIDs` 0x1004, `GetStorageInfo` 0x1005 | Each storage id becomes a domain |
| List a folder | `GetObjectPropList` 0x9805 with the folder handle, depth 1 | **Name, 64-bit size, modification date and format for the whole folder in one operation.** Only devices without it fall back to `GetObjectHandles` 0x1007 + `GetObjectInfo` 0x1008 per file. This fixes MacDroid weakness 1 |
| Read a file | `GetPartialObject64` 0x95C1 (Android extension), falling back to `GetObject` 0x1009 | Read in 1 MB chunks for progress and cancellation |
| Write a new file | `SendObjectInfo` 0x100C then `SendObject` 0x100D | The size in `ObjectInfo` is `UInt32`; files ≥ 4 GB write `0xFFFFFFFF` and set the real size through the `ObjectSize` 0xDC04 property |
| Edit an existing file | `BeginEditObject` 0x95C4, `SendPartialObject` 0x95C2, `TruncateObject` 0x95C3, `EndEditObject` 0x95C5 | Android extension. Without it, upload to a hidden temporary file, delete the old file, then rename the temporary one, so a failed upload never loses the phone's copy; plain delete-then-write only when the device cannot rename either. Edits through the extension operations get the phone's current time, not the Mac's mtime (FR-09 holds for new files only) |
| Create a folder | `SendObjectInfo` with format Association 0x3001 | |
| Delete | `DeleteObject` 0x100B | |
| Rename | `SetObjectPropValue` 0x9804, property `ObjectFileName` 0xDC07 | |
| Move | `MoveObject` 0x1019 | Without it, copy then delete, and tell the user it is slow |
| Events | interrupt endpoint: `ObjectAdded` 0x4002, `ObjectRemoved` 0x4003, `StoreAdded` 0x4004, `StoreRemoved` 0x4005, `ObjectInfoChanged` 0x4007 | Turned into `ChangeHint`s |

MTP handles are only valid within a session. After reconnecting, the path → handle table is rebuilt on demand; handles are never long-lived identifiers.

**Notes from building it (14 November 2026, not yet checked on a real phone).**

- MTP paths use the same form as ADB: internal storage is `/storage/emulated/0`, an SD card is `/storage/<label>` when the label looks like `XXXX-XXXX`, otherwise `/storage/<storage id in hex>`. That way a phone is the same drive over MTP and ADB, provided Android reports the SD card id as its label.
- Path lookups are byte-exact, as with ADB: NFC and NFD spellings are two different files on the phone. MTP dates carry no time zone; they are read and written as the Mac's local time, which assumes the phone and the Mac share a time zone.
- Removing an object that was never browsed becomes `ChangeHint.changed(root)`, meaning "something changed, location unknown": the File Provider side must refresh the whole tree.
- Android exposes MTP as class FF/FF/00 with the interface string "MTP", PTP as 6/1/1, ADB as FF/42/01.
- Cancelling a transfer must run the PTP cancel in a separate task (run inside the cancelled task, the cancel's own USB transfers abort immediately), then drain leftover IN data (about 100 ms).
- IOUSBHost has no Swift overlay: methods are named `__ioService:`, `__abort(with:)`, `__send(…)`; `kIOMessageServiceIsTerminated` and `kUSBHostReturnPipeStalled` are not imported and must be defined by value.
- Every USB interface has a `UsbExclusiveOwner` property naming its holder: kernel drivers appear by class name, user processes as `"pid N, name"`. This is how DroidDrive tells that `ptpcamerad` or MacDroid holds the phone (5.7).

**Fallback:** if building directly on `IOUSBHost` runs into trouble in the spike, use `libmtp` + `libusb` (LGPL 2.1, dynamically linked). See also OpenMTP (MIT, uses the Go library `kalam`).

### 5.4 ADB

DroidDrive has its own ADB client in Swift and never calls the `adb` binary. The protocol is documented in the AOSP sources: `packages/modules/adb/protocol.txt` and `SYNC.TXT`.

**Finding devices over USB.** Interface class 0xFF, subclass 0x42, protocol 0x01, two bulk endpoints.

**Respect a running adb server.** If the user has Android Studio, their `adb` server (port 5037 on the Mac) already holds the USB interface. DroidDrive then does not compete; it talks through that server: `host:transport:<serial>`, then `sync:`, like any adb client. With a server, use the server; without one, open USB directly. The user does not need to know.

**One phone, one identity.** adb names connections, not phones. The same phone is `R5CT20ABCDE` over USB, `192.168.1.23:41234` over Wi-Fi (the port changes every time Wireless debugging is turned back on), and `adb-R5CT20ABCDE-…._adb-tls-connect._tcp` through mDNS. So Finder drives are named after the phone's `ro.serialno` (falling back to the adb serial when the phone reports none), and all connections with the same `ro.serialno` merge into one menu row, preferring USB. Before writing, the extension checks the connection's `ro.serialno` against the drive's serial. Two different phones reporting the same serial (some cheap phones use `0123456789ABCDEF`) are told apart by different `android_id` values: then neither is mounted and the menu says "Duplicate serial".

**Handshake.** Every packet has a 24-byte header: command, arg0, arg1, data length, checksum, magic (= command XOR 0xFFFFFFFF). Commands: `CNXN`, `AUTH`, `OPEN`, `OKAY`, `WRTE`, `CLSE`, `STLS`. Send `CNXN` with version 0x01000001, max data 1 MB, banner `host::features=shell_v2,cmd,stat_v2,ls_v2,fixed_push_mkdir,…`. When the device answers with version ≥ 0x01000001, send checksum 0, like `adb`. Each stream has at most one unacknowledged `WRTE` per direction, and DroidDrive only `OKAY`s a device `WRTE` once it has consumed it, so a slow disk slows the phone down instead of piling data up in memory.

**Authentication.** Generate an RSA-2048 key pair on first run and keep it in the Keychain. The device sends `AUTH` type TOKEN; sign it and reply with type SIGNATURE. If the device does not know the key, send the public key (type RSAPUBLICKEY, Android's own `RSAPublicKey` format, base64, followed by the name `droiddrive@<hostname>`); the phone shows "Allow USB debugging?". The UI says "Unlock the phone and tap Allow".

**File operations:**

| Task | How |
|---|---|
| List | `sync:` service, `LIS2` (64-bit sizes), falling back to `LIST` without `ls_v2` |
| Stat | `STA2`, falling back to `STAT` |
| Read a whole file | `RECV` → `DATA` chunks → `DONE`. `RCV2` only adds compression and is not used; `RECV` has no 4 GB limit because data streams in chunks |
| Read a range | `exec:dd if=<path> bs=1M skip=… count=…` (a clean binary stream, unlike `shell:`). Only needed for an FSKit mount (5.5) |
| Write | `SEND` with `<path>,<mode>`, `DATA` chunks of up to 64 KB (several packed into one `WRTE`), ending with `DONE <mtime>` (keeps the mtime). `SND2` only adds compression and is not used |
| Create folder, delete, rename | `shell,v2:` running `mkdir -p`, `rm -rf`, `mv`; read the exit code |
| Storages | `shell:` running `df` and listing `/storage`; internal storage is `/storage/emulated/0`, SD cards are `/storage/XXXX-XXXX` |

**Shell safety:** paths are always wrapped in single quotes with every inner single quote escaped (`'` → `'\''`), always preceded by `--`. File names come from the user and from the phone; a file named `a'; rm -rf /sdcard; '` must never run as a command. There is a dedicated test for this.

**Wi-Fi:**

- **Android 10 and earlier, or "switch to Wi-Fi" while on a cable:** send the `tcpip:5555` service over USB, read the IP with `shell:ip route`, then open TCP to `<ip>:5555`. Remember the IP and serial to reconnect.
- **Android 11 and later, pairing:** the phone advertises the mDNS service `_adb-tls-pairing._tcp`. Pairing is SPAKE2 (password-authenticated key exchange, the password being the 6-digit code) over TLS; afterwards both sides exchange certificates and the phone stores DroidDrive's. SPAKE2 comes from BoringSSL (`include/openssl/curve25519.h`), packaged as a small C module.
- **QR code:** DroidDrive generates `WIFI:T:ADB;S:<random-service-name>;P:<random-password>;;` and draws it as a QR code. After scanning, the phone advertises `_adb-tls-pairing._tcp` with exactly that service name; DroidDrive finds it with `NWBrowser` and pairs with the password from the QR code.
- **Connecting after pairing:** the phone advertises `_adb-tls-connect._tcp`. Send `CNXN`, the phone answers `STLS`, both sides upgrade to TLS 1.3 with a self-signed certificate from the RSA key above (`sec_protocol_options_set_local_identity`), then the usual ADB handshake follows.
- **Reconnecting:** when the `_adb-tls-connect._tcp` service of a paired device shows up, connect and remount automatically.

**Notes from building Wi-Fi (14 November 2026).** Pairing works with the emulator and with the real `adb pair` (both directions); the TLS connection works with the emulator's adbd and with a real Pixel 4 XL (Android 13).

- Network.framework cannot upgrade an open TCP connection to TLS. So the connection is built as TLS over a small `NWProtocolFramer` over TCP: the framer holds TLS back, passes the plaintext `CNXN`/`STLS` itself, then steps aside.
- AOSP byte details that are easy to get wrong: the SPAKE2 names include the trailing NUL (`"adb pair client\0"`); the TLS exporter label is the 10 bytes `"adb-label\0"`; the length in the packet header is big-endian; the AES-GCM nonce is an 8-byte little-endian counter zero-padded to 12 bytes, one counter per direction; the phone's PeerInfo is the device GUID, which is also its `_adb-tls-connect._tcp` service name.
- macOS has no public call that pairs a `SecKey` with a certificate in memory. DroidDrive builds a PKCS#12 bundle and imports it: Apple ignores an unencrypted key and rejects a bundle without a MAC, so the key uses PBES2/AES-256 and the MAC is HMAC-SHA256. On macOS 13–14 the import leaves a "DroidDrive ADB TLS" identity in the login keychain (untested; the test Mac runs macOS 26).
- BoringSSL moved to C++ in late 2024; `CSpake2` comes from tag 0.20240913.0, the last release where these files are C.
- The emulator has `ro.adb.secure=0` and accepts any key; a phone rejecting the key has not been tested.
- While DroidDrive holds a phone's Wi-Fi connection, the adb server lost the phone and `adb connect` to the advertised port failed. Android may accept only one wireless debugging client at a time; to be confirmed.

### 5.5 Putting files in Finder

**File Provider, replicated** (`NSFileProviderReplicatedExtension`). Why: nothing to install, works inside and outside the App Store, and comes with offline queueing, status badges and progress in Finder.

**Stable identifiers.** File Provider requires an item's identifier to stay the same across renames and moves. Neither MTP handles nor paths do. So each domain has a SQLite table `items(id TEXT PRIMARY KEY, parent_id, name, path, kind, size, mtime, version, transport_key)`; `id` is a UUID generated the first time an item is seen. A rename updates `path` and keeps `id`. The root item uses `NSFileProviderItemIdentifier.rootContainer`.

**Item version** (for conflict detection) = `size` + `mtime` combined. When an upload finds the phone's version different from the version Finder holds, that is a conflict: keep both, renaming the Mac's copy to "Name (Mac copy).ext" (or "Name (Mac copy 2).ext"… if that name exists too). Creating a file where the phone already has a same-named file Finder does not know about is also a conflict, handled the same way; a same-named folder is merged into the existing one.

**Operation mapping:**

| File Provider calls | DroidDrive does |
|---|---|
| `enumerator(for:)` → `enumerateItems` | `transport.list`, returned in pages of 500 items so Finder fills in gradually, recorded in the ItemStore |
| `enumerateChanges` (working set) | Compare the ItemStore with the latest listing of open folders; return changed and deleted items |
| `fetchContents` | `transport.read` into a temporary file, return its URL |
| `createItem` | `mkdir` or `write` |
| `modifyItem` | Content change → `write`; rename or new parent → `rename`; mtime change → write the mtime back if the transport supports it |
| `deleteItem` | `delete(recursive: true)` |
| Connection lost mid-operation | Return `serverUnreachable`; macOS keeps the operation and calls again after DroidDrive reports `signalErrorResolved` on reconnect |

**Refresh.** Each device has a refresh interval (30 seconds by default; 10 seconds, 1 or 5 minutes, or off). On each tick, or on an MTP event, call `NSFileProviderManager.signalEnumerator(for: .workingSet)`. Only folders Finder has opened are listed again, plus folders created from the Mac (Finder never lists those); the whole phone is never scanned. When a device has just reconnected, signal immediately (`signalErrorResolved` then `signalEnumerator`) instead of waiting for the interval, to meet FR-10.

**Enabling the drive.** On macOS 26 (tested 14 November 2026, see `spikes.md`) a new domain starts disabled until the user turns DroidDrive on under System Settings → General → Login Items & Extensions → File Providers. Until then every operation in the folder times out. The app reads `NSFileProviderDomain.userEnabled` and, while a domain is disabled, replaces the menu with instructions and a button that opens that settings page.

**Unmounting and losing the connection.** Pulling the cable keeps the domain, and downloaded files still open (FR-10). Unmount and Remove Device use `NSFileProviderManager.remove(domain, mode: .preserveDirtyUserData)` and ask first if a transfer is running. Observed on 14 November 2026: in both preserving modes macOS leaves a "<drive name> (date)" folder holding files created on the Mac, even ones already uploaded, and a sandboxed app may not delete it. Calling `NSFileProviderManager.add` with an existing identifier renames the drive; this is used to rename drives named by older builds.

**Status in Finder.** Finder draws cloud badges for not downloaded, downloading, waiting to upload and upload failed. A conflict copy gets an extra badge through File Provider decorations (`NSFileProviderDecorations` in the extension's Info.plist).

**File Provider limits to know up front:** opening a file downloads the whole file, so watching a 10 GB video means copying 10 GB first. The drive lives at `~/Library/CloudStorage/DroidDrive-<domain-name>`, not under `/Volumes/`. And listing a large folder the first time is slow (section 9).

**FSKit (spike S0-d, not adopted).** FSKit on macOS 26 can mount a file system backed by a URL (`FSGenericURLResource`) instead of a block device, and lists 10,000 entries in 0.11 seconds against 401 seconds through File Provider. It was not adopted: on macOS 26.x the System Settings switch cannot enable a third-party FSKit module (a macOS bug, fixed in 27.0), and a sandboxed app cannot run `mount -F` itself. DroidDrive is for personal use, so File Provider stays. Details in `spikes.md`.

### 5.6 File names, times, sizes

- **Unicode normalization.** macOS may hand over names in NFD (decomposed accents); Android stores the bytes it receives. Names sent to the phone are always converted to NFC. Name comparisons (duplicates, conflicts) use NFC. Without this, "Đà Lạt.jpg" from the Mac becomes a different file from "Đà Lạt.jpg" taken on the phone. Names read from the phone keep their exact bytes (an Android app may have created an NFD name), because those bytes are needed to address the file again. Note for code: Swift's `String ==` compares by canonical equivalence, so NFC and NFD compare equal; byte checks must compare `.utf8`.
- **Characters Android rejects** in names on shared storage (`"*/:<>?\|`): refuse with a clear error, never rename silently.
- **Sizes** are always `UInt64`. MTP uses the `ObjectSize` property, ADB uses `LIS2`/`STA2`.
- **Out of space:** check free space before writing files larger than 100 MB and fail early with `noSpace` instead of half way. When overwriting, only the growth over the old file needs space.

### 5.7 Device held by another process

When opening the USB interface returns `kIOReturnExclusiveAccess`:

1. Find the holder: walk the device's IORegistry subtree and read the interface's client property (`IOUserClientCreator` looks like `pid 2100, ptpcamerad`).
2. Show "In use by <process-name>" with advice per case:
   - `ptpcamerad`: explain that it is the macOS photo service and offer "Try again" together with the command that stops it (`killall ptpcamerad`; it runs under the user's account); if it grabs the device again, suggest switching to ADB.
   - Android File Transfer, Smart Switch, OpenMTP, Android Studio's adb server (ADB is covered in 5.4): ask the user to quit that app.
3. Retry automatically every 3 seconds for 30 seconds.

The behaviour of `ptpcamerad` on macOS 26 is not verified yet; it is the first task of the spike phase (section 11).

## 6. User interface

**Menu bar (always present).** A phone icon; a filled icon when a device is mounted, a transfer icon while transferring. Menu:

```
Pixel 8 (ADB · USB)                ● Mounted
   Open in Finder
   Unmount
   Switch to Wi-Fi
Galaxy Tab S9 (MTP · USB)          ⚠ In use by ptpcamerad
   How to fix…
───────────────
Connect via Wi-Fi…
Transfer Log
Settings…
Quit DroidDrive
```

**Devices window.** A sidebar lists devices (all ever connected, dimmed when absent). The main pane: model, Android version, connection kind, each storage with a capacity bar, MTP/ADB choice, Mount/Unmount, refresh interval, Remove Device. When a phone is plugged in without "File transfer" or without allowing ADB, the main pane is a step-by-step guide, not an error message.

**Connect via Wi-Fi (sheet).** Four tabs: QR code (default), Pairing code, Manual (IP, port, code), Android 10 and earlier (IP). The Pairing code tab lists the phones currently advertising `_adb-tls-pairing._tcp`; the user just picks one and types 6 digits.

**Transfer log.** A table: time, device, file, direction (↓ to the Mac, ↑ to the phone), size, average speed, result. Filter by device and result, a button to clear the log. Kept for 7 days.

**Language.** The UI is English only, including drive names, conflict-copy names and error messages (decided 14 November 2026). The repository docs are English as well (since the repository became public open source, 15 November 2026).

## 7. Settings

| Item | Default | Notes |
|---|---|---|
| Open at login | On | `SMAppService.mainApp` |
| Mount automatically when a device connects | On | |
| Preferred mode when both MTP and ADB are available | ADB | |
| Default refresh interval | 30 seconds | Can be overridden per device |
| How long unused downloaded files are kept | Left to macOS | File Provider cleans up when space runs low; a "Free Up Space" button cleans up now |
| Notify when a transfer larger than this finishes | 500 MB | |
| Pairing key | | "Generate new ADB key" button (phones will ask to allow again) |

Nothing is hidden behind the Option key.

## 8. Permissions, entitlements, distribution

| Needed | Why |
|---|---|
| App Sandbox + `com.apple.security.device.usb` | Open USB devices |
| `com.apple.security.network.client` and `network.server` | ADB over TCP; the server side for pairing |
| `NSLocalNetworkUsageDescription` + `NSBonjourServices` with `_adb-tls-pairing._tcp`, `_adb-tls-connect._tcp`, `_adb._tcp` | Local network permission (mandatory since macOS 15); MacDroid 2.3 also had to add a check for it |
| App group `<TEAMID>.com.droiddrive` | Share the ItemStore and the transfer log between app and extension |
| Keychain | The ADB RSA key |

Distribution: Developer ID and notarization when a public build is wanted (`scripts/release.sh`); no update feed yet. Everything above is Mac App Store compatible, so it could go there later.

Minimum macOS: 13 (Ventura). Apple silicon and Intel (universal binary).

## 9. Performance

Measured relative to the standard tools on the same Mac and cable, so the numbers do not depend on hardware.

| Metric | Target |
|---|---|
| ADB over USB, 1 GB file | ≥ 80% of `adb push` / `adb pull` |
| MTP over USB | ≥ 80% of OpenMTP or MacDroid on the same device |
| Listing a 1,000-file folder | ≤ 1.5 seconds (ADB), ≤ 3 seconds (MTP with `GetObjectPropList`) |
| Listing a 10,000-file folder | First page ≤ 2 seconds, complete ≤ 15 seconds |
| App memory when idle | ≤ 150 MB |
| CPU when idle with 2 devices mounted | ≤ 1% on average |

Measured on 14 November 2026 (details in `spikes.md`): extension memory 16–17 MB, app 40–55 MB; app CPU 0.96% when idle with 3 drives of 2 phones; transfer speed meets the target on the emulator and on a Pixel over Wi-Fi. **Listing through Finder misses the target**: a 1,000-file folder takes 30 seconds the first time it opens, although the extension returns each 500-entry page in under 0.25 seconds. The time is fileproviderd creating a placeholder file per entry, about 30 ms each on the test Mac. With replicated File Provider the 1.5 and 15 second targets cannot be met.

## 10. Testing

- **Unit tests:** encoding and decoding of MTP, ADB and sync packets; AUTH signing; name normalization; shell quoting (including malicious file names); ItemStore renames and moves keeping identifiers.
- **Integration tests with a fake transport:** an in-memory `DeviceTransport` driving the whole File Provider flow (listing, download, edit, connection lost mid-way, conflicts).
- **ADB with the Android Emulator** over TCP, runnable on macOS CI: push, pull, 5 GB file, 10,000 files, Vietnamese names.
- **Real devices** (MTP and ADB over USB cannot be emulated): at minimum a Pixel (Android 16), a Samsung (One UI, Android 14 or later), a Xiaomi, an Android 10 phone and a Kindle. Every release runs FR-01 → FR-20 by hand on this matrix.
- **macOS:** 13, 15, 26.

## 11. Roadmap

Each phase is done when the criteria in the last column are met.

| Phase | Content | Done when |
|---|---|---|
| 0. Spikes | (a) open the MTP interface with `IOUSBHost` on macOS 26 while `ptpcamerad` runs; (b) ADB handshake over USB up to `sync:` `LIST`; (c) replicated File Provider with a fake transport visible in Finder; (d) can FSKit mount a file system not backed by a block device | A yes/no answer for all four in `docs/spikes.md`. If (a) fails, switch to `libmtp` |
| 1. ADB MVP | ADB over USB, File Provider read/write, menu bar, Unicode names, files > 4 GB | FR-01, 03 → 10, 19 pass on a Pixel and a Samsung |
| 2. MTP | MtpTransport, busy-device handling, MTP events | FR-02, 11, 16 pass; a 10,000-file folder lists completely over MTP |
| 3. Wi-Fi | `tcpip` for Android ≤ 10, SPAKE2 pairing, QR, reconnect | FR-12 → 15 pass |
| 4. Finishing | Transfer log, settings, illustrated guidance, notarization | FR-17, 18, 20 pass; a notarized build runs on a clean Mac |
| 5. Optional | App Intents for Shortcuts, Mac App Store, paid tier | As decided then |

## 12. Risks

| Risk | Impact | Mitigation |
|---|---|---|
| `ptpcamerad` holds the MTP interface and grabs it again after being stopped | MTP unusable on some Macs | Spike 0a; ADB is the main route, MTP the secondary one |
| Vendors implement MTP off-spec (no `GetObjectPropList`, no Android extension operations) | Slow or missing operations | Check `DeviceInfo` and have a fallback for every extension operation |
| Wi-Fi pairing (SPAKE2 + TLS) is hard to get right | Phase 3 takes longer | Compare with the AOSP code `pairing_auth` and `pairing_connection`, and the TypeScript of Tango (ya-webadb) |
| File Provider downloads the whole file before opening it | Large videos are slow to open | Say so in the docs |
| Newer Android blocks `Android/data` and `Android/obb` for the ADB shell | Some folders show empty | Show the folder with a note "Android does not allow access", not an error |
| A sync bug loses data on the phone | Severe | Delete and overwrite only when versions match; keep both copies on conflict; conflict tests in the integration suite |

## 13. Decisions

The user accepted all recommendations on 13 November 2026, and made later decisions as noted. The implementation plan is in [`plan.md`](plan.md).

| # | Decision | Decided |
|---|---|---|
| 1 | How files reach Finder | File Provider (replicated) only. FSKit was tried in spike S0-d and not adopted (15 November 2026, see 5.5). No macFUSE, no network drive |
| 2 | Minimum macOS | macOS 13 (Ventura), universal binary |
| 3 | USB library | Own code on `IOUSBHost`. `libmtp` + `libusb` only as a fallback if spike 0a fails |
| 4 | ADB client | Own Swift code; use the user's adb server (port 5037) when it runs; never bundle the `adb` binary |
| 5 | Free/PRO tiers | Not in the first release; only a licence-check flag in the code |
| 6 | Order | ADB first (phase 1), MTP second (phase 2) |
| 7 | Name | "DroidDrive" is a working name; check for trademark conflicts before a public release |
| 8 | UI language | English only (14 November 2026) |
| 9 | Audience | Personal use first (15 November 2026); distribution-only work is low priority |

## 14. Sources

MacDroid (read on 13 November 2026):

- [Home](https://www.macdroid.app/), [Purchase](https://www.macdroid.app/purchase/), [FAQ](https://www.macdroid.app/faq/), [General info](https://www.macdroid.app/faq/macdroid-general-info/)
- [Mount types](https://www.macdroid.app/faq/types-of-drive-mouting-used-in-macdroid/), [Preferences](https://www.macdroid.app/faq/macdroid-preferences/), [Device options](https://www.macdroid.app/faq/device-options/), [Status icons](https://www.macdroid.app/faq/what-do-the-icons-on-my-files-mean/)
- [MTP connection](https://www.macdroid.app/faq/connect-and-mount-android-device-using-mtp/), [ADB connection](https://www.macdroid.app/faq/connect-and-mount-android-device-using-adb/), [Wi-Fi connection](https://www.macdroid.app/faq/how-to-connect-android-device-using-wi-fi/)
- [Folders with many files](https://www.macdroid.app/faq/cannot-access-a-folder-with-a-large-quantity-of-files/), [Device used by another app](https://www.macdroid.app/faq/cannot-connect-a-phone-while-it-is-being-used-by-another-app/)
- [Version history](https://help.electronic.us/support/solutions/articles/44001895298-macdroid-version-history)

Technical:

- [FSKit](https://developer.apple.com/documentation/fskit), [FSUnaryFileSystem](https://developer.apple.com/documentation/fskit/fsunaryfilesystem), [FSKitSample](https://github.com/drunlin/FSKitSample), [FSKit enablement bug on macOS 26](https://github.com/MacFabric/iSCSI-NVMe-TCP/blob/main/docs/feedback-fskit-enablement-26x.md)
- [Android Debug Bridge](https://developer.android.com/tools/adb); protocol: AOSP `packages/modules/adb` (`protocol.txt`, `SYNC.TXT`, `pairing_auth/`, `pairing_connection/`)
- [Commit adding TLS and mDNS to adb Wi-Fi](https://gerrit.omnirom.org/plugins/gitiles/android_system_core/+/d85f5c013089d569a6274ae5ab01cfaa613fc872%5E%21), [wadb](https://github.com/lindevhard/wadb), [adb-qr](https://pypi.org/project/adb-qr/)
- `ptpcamerad` holding devices: [Apple Community](https://discussions.apple.com/thread/254788819), [MTP in Rust on macOS](https://dev.to/hiyoyok/building-an-android-file-transfer-alternative-for-macos-why-it-had-to-be-rust-1m0h), [droidmount](https://awesome.ecosyste.ms/projects/github.com%2Frahuletto%2Fdroidmount)
- Android's MTP extension operation codes: AOSP `frameworks/av/media/mtp/mtp.h`
