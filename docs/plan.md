# Kế hoạch thực hiện DroidDrive

Tài liệu này là kế hoạch làm DroidDrive, ứng dụng macOS gắn điện thoại Android vào Finder theo đặc tả [`spec.md`](spec.md). Đặc tả trả lời câu hỏi "làm cái gì"; tài liệu này trả lời "làm theo thứ tự nào, mỗi bước gồm việc gì, xong khi nào, và trước khi bắt đầu cần chuẩn bị gì".

Trạng thái tối 14/11/2026: đã có code cho cả bốn giai đoạn đầu. Phần chạy được không cần điện thoại cắm cáp đã thử với Android Emulator và với một Pixel 4 XL thật (Android 13) nối qua Wi-Fi bằng adb server. USB và MTP mới chỉ chạy với điện thoại giả trong bộ nhớ, vì chưa cắm máy thật lần nào; ghép đôi Wi-Fi của chính DroidDrive đã thử với emulator và với `adb pair` thật. Kết quả các bài thử ở [`spikes.md`](spikes.md).

Cột **Xong** trong các bảng việc: ✅ đạt tiêu chí "Xong khi" (trên emulator nếu tiêu chí không đòi máy thật), ◐ làm một phần, để trống là chưa làm. Phần còn thiếu của từng việc ghi ở mục 5.

Cách chia việc: đi từ chỗ rủi ro cao nhất. Giai đoạn 0 là bốn bài thử nhỏ, mỗi bài trả lời một câu hỏi có/không mà nếu trả lời sai thì phải đổi thiết kế. Sau đó mỗi giai đoạn ra một bản chạy được trên máy thật, xong khi các yêu cầu chức năng (mã `FR-xx` ở mục 4 của đặc tả) của giai đoạn đó đạt.

## 1. Cần chuẩn bị trước khi bắt đầu

1. **Tài khoản Apple Developer (trả phí, 99 USD/năm).**
   Đề xuất: dùng tài khoản đang có nếu có, tạo Team ID riêng không cần. Lý do: App Group, Developer ID và notarize đều cần tài khoản trả phí; File Provider extension chạy được khi ký bằng tài khoản miễn phí trong lúc phát triển, nhưng không phân phối được.
   Nếu không: giai đoạn 0 và 1 vẫn làm được với chữ ký phát triển, chỉ chặn ở giai đoạn 4 (notarize).
2. **Thiết bị test.**
   Đề xuất: tối thiểu một Pixel (Android 15 hoặc 16) và một Samsung (Android 14 trở lên) trước giai đoạn 1; thêm một máy Android 10 trở xuống trước giai đoạn 3 (cho `tcpip`); một Kindle hoặc GoPro là tùy chọn ở giai đoạn 2.
   Nếu chỉ có một máy: làm được, nhưng lỗi riêng của One UI (Samsung) sẽ chỉ lộ ra khi người khác dùng.
3. **Máy Mac test.**
   Đề xuất: máy chính chạy macOS 26; một máy ảo macOS 13 (UTM hoặc Parallels trên Apple silicon) để kiểm bản tối thiểu. Lưu ý: máy ảo không chuyển tiếp USB ổn định, nên trên máy ảo chỉ test ADB qua Wi-Fi.
4. **Công cụ:** Xcode bản mới nhất, Android Studio (để có emulator và `adb` làm mốc đo tốc độ), OpenMTP (mốc đo tốc độ MTP).

## 2. Cấu trúc repo dự kiến

Code chia thành Swift package theo lớp, để test được từng lớp mà không cần app hay extension. Ứng dụng và extension chỉ là lớp vỏ mỏng gọi vào các package.

Lúc làm, các lớp thành **một** Swift package `Packages/` với mỗi lớp một target (thay vì mỗi lớp một package), để một lệnh `swift test` chạy test của mọi lớp. Project Xcode sinh từ `project.yml` bằng XcodeGen, không commit.

```
android-mac-transfer/
├── docs/                    spec.md, plan.md, spikes.md
├── project.yml              XcodeGen → DroidDrive.xcodeproj (git-ignored)
├── Config/Signing.xcconfig  team và tiền tố bundle id; ghi đè ở Signing.local.xcconfig
├── App/                     target ứng dụng thanh menu (SwiftUI)
├── FileProvider/            target NSFileProviderReplicatedExtension
├── Shared/                  mã dùng chung app + extension (app group)
├── Packages/
│   ├── Package.swift
│   ├── Sources/
│   │   ├── DroidCore/       DeviceTransport, RemoteEntry, lỗi chung, chuẩn hóa tên, DomainIdentifier, FakeTransport
│   │   ├── ItemStore/       SQLite: identifier ↔ đường dẫn, version, generation + tombstone
│   │   ├── AdbKit/          gói tin ADB, AUTH, sync, shell, kết nối TCP / qua adb server, AdbTransport
│   │   ├── DroidDriveCLI/   droiddrive-cli: chạy thử và đo tốc độ, không đóng gói vào app
│   │   ├── UsbKit/          (chưa có) IOUSBHost
│   │   ├── AdbPairing/      (chưa có) SPAKE2 + TLS, mDNS, QR
│   │   ├── MtpKit/          (chưa có) PTP/MTP
│   │   └── DeviceService/   (chưa có) DeviceSession, TransferQueue, ActivityLog, XPC
│   └── Tests/               unit test từng lớp, IntegrationTests (cần thiết bị), fixtures
└── Tests/fixtures/          malicious-names.bin (tên tệp độc hại, phân cách NUL)
```

## 3. Các giai đoạn

Ước lượng là thô, tính cho một người làm toàn thời gian, chủ yếu để thấy tỉ lệ giữa các giai đoạn. Tổng khoảng 11 đến 13 tuần.

| Giai đoạn | Nội dung | Ước lượng | Tiến độ (14/11/2026) |
|---|---|---|---|
| 0 | Bốn bài thử | 1 tuần | 2/4 ✅, 1 ◐ |
| 1 | MVP qua ADB + USB | 3 tuần | 6/14 ✅, 8 ◐ |
| 2 | MTP | 3 tuần | 0/9 ✅, 8 ◐ (chỉ thử với điện thoại giả) |
| 3 | Wi-Fi | 2–3 tuần | 5/8 ✅, 3 ◐ |
| 4 | Hoàn thiện và phát hành | 2 tuần | 4/8 ✅, 4 ◐ |
| 5 | Tùy chọn (FSKit, Shortcuts, App Store) | chưa ước lượng | |

### Giai đoạn 0: bốn bài thử

Mỗi bài là một chương trình nhỏ bỏ đi sau khi xong, chỉ giữ lại kết luận. Kết quả ghi vào `docs/spikes.md`: câu hỏi, cách thử, máy và phiên bản, kết quả, hệ quả cho thiết kế.

| Mã | Xong | Câu hỏi | Cách thử | Nếu "không" |
|---|:-:|---|---|---|
| S0-a |  | Mở được giao diện MTP của điện thoại bằng `IOUSBHost` trên macOS 26 không, khi `ptpcamerad` đang chạy? Dừng `ptpcamerad` thì nó có chiếm lại không? | CLI Swift: tìm giao diện MTP, mở độc quyền, gửi `GetDeviceInfo`, `OpenSession`. Lặp lại sau `killall ptpcamerad`. Thử trên Pixel và Samsung | Thử `libmtp` + `libusb`; nếu cũng không được thì MTP chỉ là "thử nghiệm" trong bản đầu, đặc tả cập nhật mục 5.7 |
| S0-b | ◐ | Tự viết được bắt tay ADB qua USB tới `sync:` `LIST` không? | CLI Swift: tìm giao diện ADB, `CNXN`, `AUTH` (sinh khóa RSA, ký token), mở `sync:`, liệt kê `/sdcard` | Không có phương án thay thế tốt; đây là bài phải đạt. Nếu kẹt quá 3 ngày, cân nhắc đóng gói `adb` (quyết định 4 phải mở lại) |
| S0-c | ✅ | File Provider replicated với dữ liệu giả có hiện trong Finder, đọc, ghi, đổi tên, và mất kết nối giả lập có đưa thao tác vào hàng đợi không? | App + extension tối thiểu, transport giả trong bộ nhớ, giao tiếp qua XPC Mach service trong app group | Không có phương án thay thế trong phạm vi đã chốt; ghi rõ giới hạn gặp phải và hỏi lại người dùng |
| S0-d | ✅ | FSKit trên macOS 26 có gắn được hệ thống tệp không dựa trên thiết bị khối không? | Đọc tài liệu FSKit bản mới nhất, dựng extension `FSUnaryFileSystem` từ FSKitSample, thử gắn với tài nguyên kiểu URL hoặc đường dẫn | Bỏ FSKit khỏi giai đoạn 5, ghi lý do |

Xong khi: `docs/spikes.md` có kết luận cho cả bốn, và đặc tả được cập nhật nếu kết luận nào làm đổi thiết kế.

### Giai đoạn 1: MVP qua ADB và USB

Mục tiêu: cắm điện thoại đã bật Gỡ lỗi USB, điện thoại hiện trong Finder, làm được mọi thao tác tệp.

| Mã | Xong | Việc | Phụ thuộc | Xong khi |
|---|:-:|---|---|---|
| P1-01 | ◐ | Tạo Xcode project, hai target, App Group, entitlement (mục 8 của đặc tả), các package rỗng, CI build + test | | CI xanh trên một commit rỗng |
| P1-02 | ✅ | `DroidCore`: `DeviceTransport`, `RemoteEntry`, enum lỗi, chuẩn hóa NFC, kiểm ký tự cấm, `FakeTransport` | P1-01 | Unit test cho chuẩn hóa và ký tự cấm |
| P1-03 | ◐ | `UsbKit`: theo dõi cắm rút, mở giao diện, bulk pipe, đọc ghi bất đồng bộ, đọc tiến trình đang chiếm | P1-01 | CLI in ra danh sách thiết bị và giao diện khi cắm rút |
| P1-04 | ✅ | `AdbKit` gói tin: mã hóa, giải mã, checksum, bộ đọc luồng | P1-02 | Unit test với các gói mẫu lấy từ `adb` thật (bắt bằng Wireshark hoặc log của adb) |
| P1-05 | ◐ | `AdbKit` xác thực: sinh RSA 2048, lưu Keychain, ký token, định dạng khóa công khai Android | P1-04 | Điện thoại hiện hộp thoại cho phép; lần sau không hỏi lại |
| P1-06 | ◐ | `AdbKit` sync: `LIS2`/`LIST`, `STA2`/`STAT`, `RCV2`/`RECV`, `SND2`/`SEND` có mtime | P1-05 | Push và pull tệp 6 GB, SHA-256 khớp |
| P1-07 | ✅ | `AdbKit` shell: `shell,v2` có mã thoát, thoát đường dẫn an toàn, `mkdir`, `rm`, `mv`, `df`, liệt kê `/storage` | P1-05 | Unit test với bộ tên tệp độc hại trong `Tests/fixtures`; không tên nào chạy thành lệnh |
| P1-08 | ✅ | `AdbKit` qua adb server: phát hiện cổng 5037, `host:transport:<serial>`, rồi dùng chung sync và shell | P1-06 | Mở Android Studio trước, DroidDrive vẫn gắn được điện thoại |
| P1-09 | ◐ | `AdbTransport`: cài `DeviceTransport` trên `AdbKit`, liệt kê theo lô, 4 luồng song song | P1-06, P1-07 | Test tích hợp với Android Emulator qua TCP chạy trên CI |
| P1-10 | ✅ | `ItemStore`: schema SQLite, UUID ổn định, đổi tên giữ identifier, version, ghi nhận xung đột | P1-02 | Unit test đổi tên, di chuyển, xung đột |
| P1-11 | ✅ | `DeviceService`: DeviceManager, DeviceSession, XPC server, truyền file descriptor | P1-09 | Extension giả gọi qua XPC liệt kê được thư mục |
| P1-12 | ◐ | Extension File Provider: một domain mỗi bộ nhớ, enumerate theo trang, fetch, create, modify, delete, mất kết nối | P1-10, P1-11 | FR-03 đến FR-10 đạt với emulator |
| P1-13 | ◐ | Ứng dụng thanh menu: danh sách thiết bị, Mở trong Finder, Gắn/Tháo, hướng dẫn bật Gỡ lỗi USB, mở cùng hệ thống | P1-11 | FR-01, FR-19 đạt |
| P1-14 | ◐ | Chạy bảng FR của giai đoạn trên Pixel và Samsung thật, sửa lỗi | P1-12, P1-13 | FR-01, FR-03 đến FR-10, FR-19 đạt trên cả hai máy |

### Giai đoạn 2: MTP

Mục tiêu: điện thoại không bật Gỡ lỗi USB vẫn dùng được, thư mục 10.000 tệp hiện đủ.

| Mã | Xong | Việc | Phụ thuộc | Xong khi |
|---|:-:|---|---|---|
| P2-01 | ◐ | `MtpKit` gói tin: tiêu đề 12 byte, dữ liệu, phản hồi, sự kiện; kiểu dữ liệu PTP (chuỗi UTF-16, mảng) | P1-03 | Unit test với gói mẫu bắt từ OpenMTP |
| P2-02 | ◐ | `MtpKit` phiên: `GetDeviceInfo`, `OpenSession`, đọc danh sách lệnh thiết bị hỗ trợ, khóa một lệnh một lúc | P2-01 | CLI in thông tin máy và bộ nhớ |
| P2-03 | ◐ | Liệt kê bằng `GetObjectPropList`, đường rơi về `GetObjectHandles` + `GetObjectInfo` | P2-02 | Thư mục 10.000 tệp liệt kê đủ, đo thời gian theo mục 9 của đặc tả |
| P2-04 | ◐ | Đọc (`GetPartialObject64`, rơi về `GetObject`), ghi (`SendObjectInfo` + `SendObject`, tệp ≥ 4 GB), sửa (lệnh mở rộng Android, rơi về xóa rồi ghi) | P2-02 | Tệp 6 GB sang và về, SHA-256 khớp |
| P2-05 | ◐ | Tạo thư mục, xóa, đổi tên, di chuyển (có đường rơi về chép rồi xóa) | P2-02 | Mỗi thao tác thấy được trong ứng dụng Files trên điện thoại |
| P2-06 | ◐ | Sự kiện qua interrupt endpoint → `ChangeHint` → `signalEnumerator` | P2-02, P1-12 | Chụp ảnh mới, ảnh hiện trong Finder không đợi chu kỳ làm mới (FR-11) |
| P2-07 | ◐ | `MtpTransport` và chọn chế độ MTP/ADB theo thiết bị, nhớ lựa chọn | P2-03 đến P2-05 | FR-02 đạt |
| P2-08 | ◐ | Thiết bị bị chiếm: đọc tiến trình giữ, trạng thái và gợi ý theo từng ứng dụng, thử lại tự động, theo kết luận của S0-a | P2-02 | FR-16 đạt với `ptpcamerad` và với OpenMTP đang mở |
| P2-09 |  | Chạy bảng FR trên Pixel, Samsung, và Kindle hoặc GoPro nếu có | P2-07, P2-08 | FR-02, FR-11, FR-16 đạt; FR-04 đến FR-08 đạt cả qua MTP |

### Giai đoạn 3: Wi-Fi

| Mã | Xong | Việc | Phụ thuộc | Xong khi |
|---|:-:|---|---|---|
| P3-01 | ◐ | ADB qua TCP thường: `tcpip:5555` qua USB, đọc IP, kết nối, nhớ thiết bị | P1-09 | FR-14 đạt trên máy Android 10 |
| P3-02 | ✅ | `AdbPairing`: module C SPAKE2 từ BoringSSL, đối chiếu với `pairing_auth` của AOSP | | Unit test với vector mẫu sinh từ `adb pair` thật |
| P3-03 | ✅ | Ghép đôi qua TLS: trao chứng chỉ, lưu chứng chỉ thiết bị | P3-02 | Ghép đôi bằng mã 6 số thành công với Pixel |
| P3-04 | ✅ | mDNS: duyệt `_adb-tls-pairing._tcp` và `_adb-tls-connect._tcp` bằng `NWBrowser`, quyền mạng cục bộ | P1-01 | Danh sách điện thoại đang chờ ghép đôi hiện trong sheet |
| P3-05 | ✅ | Kết nối TLS sau ghép đôi: `CNXN` → `STLS` → TLS 1.3 với chứng chỉ của khóa RSA | P3-03 | Gắn ổ qua Wi-Fi, FR-06 đạt qua Wi-Fi |
| P3-06 | ✅ | Mã QR: sinh tên dịch vụ và mật khẩu, vẽ QR, chờ điện thoại quảng bá rồi ghép đôi | P3-03, P3-04 | FR-12 đạt |
| P3-07 | ◐ | Sheet Kết nối qua Wi-Fi với bốn tab, nhập tay IP:cổng:mã | P3-05 | FR-13 đạt |
| P3-08 | ◐ | Tự kết nối lại khi thấy thiết bị đã ghép đôi | P3-05 | FR-15 đạt |

### Giai đoạn 4: hoàn thiện và phát hành

| Mã | Xong | Việc | Xong khi |
|---|:-:|---|---|
| P4-01 | ◐ | Cửa sổ Thiết bị đầy đủ (mục 6 của đặc tả), hướng dẫn có hình cho "Truyền tệp" và Gỡ lỗi USB | Người chưa từng dùng gắn được điện thoại không cần hỏi |
| P4-02 | ✅ | Nhật ký truyền tệp: lưu 7 ngày, lọc, tốc độ | FR-17 đạt |
| P4-03 | ✅ | Trạng thái tệp trong Finder, decoration nếu cần | FR-18 đạt |
| P4-04 | ✅ | Cài đặt (mục 7 của đặc tả), chu kỳ làm mới theo thiết bị, Xóa thiết bị | FR-20 đạt |
| P4-05 | ✅ | Giao diện chỉ tiếng Anh (đổi ngày 14/11/2026, trước là tiếng Việt và tiếng Anh) | Không còn chuỗi tiếng Việt nào trong UI, tên ổ, tên bản xung đột, thông báo lỗi |
| P4-06 | ◐ | Đo hiệu năng theo mục 9 của đặc tả, sửa chỗ không đạt | Bảng số đo ghi vào `docs/benchmarks.md` |
| P4-07 | ◐ | Ký Developer ID, notarize, Sparkle, trang tải | Bản notarized cài trên máy sạch, tự cập nhật lên bản kế tiếp |
| P4-08 | ◐ | Chạy toàn bộ FR-01 đến FR-20 trên ma trận thiết bị và macOS 13, 15, 26 | Không còn lỗi mất dữ liệu; lỗi còn lại được ghi trong ghi chú phát hành |

### Giai đoạn 5: tùy chọn

Chỉ lên kế hoạch chi tiết khi giai đoạn 4 xong và người dùng chọn làm: FSKit (nếu S0-d đạt), App Intents cho Shortcuts, Mac App Store, gói trả phí.

## 4. Cách làm trong từng việc

- Viết test trước cho các lớp gói tin, ItemStore, chuẩn hóa tên, thoát đường dẫn; độ phủ tối thiểu 80% cho các package trong `Packages/`.
- Mỗi việc là một nhánh và một pull request, tên nhánh theo mã việc (`p1-06-adb-sync`).
- Mọi thao tác ghi hoặc xóa trên điện thoại phải có test xung đột trước khi gộp vào nhánh chính.
- Khi một kết luận trong lúc làm khác với đặc tả, sửa đặc tả trong cùng pull request.

## 5. Theo dõi tiến độ

Chưa có nơi theo dõi riêng; trạng thái từng việc ghi ở đây và ở pull request. Nếu cần, có thể tạo một project trong IndieWork với mỗi giai đoạn là một milestone và mỗi mã việc ở trên là một task.

Trạng thái tối 14/11/2026. "Emulator" là Android Emulator (Android 15); "Pixel" là Pixel 4 XL thật (Android 13) nối qua Wi-Fi bằng adb server; "điện thoại giả" là thiết bị MTP giả trong bộ nhớ của bộ test.

| Mã | Đã có | Còn lại |
|---|---|---|
| S0-a | Công cụ `droiddrive-usb` (`list`, `mtp-info`, `mtp-ls`, `mtp-pull`, `adb-info`) | Chạy với Pixel và Samsung cắm cáp, trước và sau `killall ptpcamerad` |
| S0-b | Đạt qua TCP và qua adb server; ADB qua USB chạy với ống USB giả | Chạy qua USB thật |
| S0-c | Đạt | |
| S0-d | Có: FSKit gắn được từ URL, liệt kê 10.000 mục trong 0,11 giây so với 401 giây qua File Provider (xem `spikes.md`) | Công tắc của Cài đặt hệ thống không bật được module bên thứ ba; quyết định có chuyển sang FSKit hay không |
| P1-01 | Project, hai target, app group, entitlement; `.github/workflows/ci.yml` (test package, build app không ký) | Chạy CI trên GitHub |
| P1-02 | Xong | |
| P1-03 | `UsbKit`: theo dõi cắm rút, nhận diện giao diện, đọc tiến trình đang giữ, `UsbPacketLink`; app có nguồn ADB-USB tự dùng khi không có adb server | Mở giao diện USB thật lần đầu |
| P1-04 | Xong | |
| P1-05 | Khóa trong Keychain (`AdbKeyStore`), app và CLI dùng chung | Thấy hộp thoại "Cho phép" trên máy thật khi DroidDrive tự nối USB |
| P1-06 | 1 GB trên emulator, 300 MB trên Pixel qua Wi-Fi, khớp SHA-256 | Tệp 6 GB |
| P1-07 | Xong | |
| P1-08 | Xong; ổ đặt tên theo `ro.serialno` | |
| P1-09 | Test tích hợp đạt trên emulator và Pixel (`DROIDDRIVE_TEST_ROOT`) | Chạy trên CI |
| P1-10 | Xong | |
| P1-11 | App giữ kết nối, extension gọi qua XPC (service của File Provider + Darwin notification, xem đặc tả 5.1); chạy cả khi app tắt rồi mở lại | |
| P1-12 | FR-03 → 06, 08 → 11 đạt trên emulator; trên Pixel: tạo, đổi tên, di chuyển, sửa, xóa, tên tiếng Việt, xung đột | FR-07 (6 GB) |
| P1-13 | Menu, cửa sổ Devices, gắn thêm bộ nhớ xuất hiện sau (thẻ SD), FR-19 | FR-01 qua USB thật |
| P1-14 | Pixel qua Wi-Fi (adb server, rồi kết nối riêng của DroidDrive): 7/8 test tích hợp đạt, tốc độ ≥ 80% `adb` | Pixel qua USB, Samsung; trang đầu thư mục 10.000 tệp đo được 2,27 giây (mục tiêu 2) khi đang chia băng thông, cần đo lại riêng |
| P2-01 → P2-08 | `MtpKit`, `MtpTransport` qua cùng bộ kiểm tra như ADB; app có nguồn MTP; nhận diện `ptpcamerad`, Android File Transfer, OpenMTP, MacDroid… kèm lời khuyên | Mọi thứ trên máy thật; gói mẫu bắt từ OpenMTP; chọn MTP/ADB cho từng máy ngoài cài đặt chung |
| P2-09 | | Cần máy thật |
| P3-01 | `TcpipSwitch`, tab "Android 10 and earlier" | Chạy với máy Android ≤ 10 |
| P3-02 | Xong, kiểm với mô hình tham chiếu và với `adb pair` thật | |
| P3-03 | Ghép đôi với Pixel thật bằng QR (người dùng làm, 14/11/2026); mã 6 số với emulator; `adb pair` thật ghép được với `PairingServer` của DroidDrive | Mã 6 số với điện thoại thật |
| P3-04 | Xong; thấy được Pixel thật qua mDNS | |
| P3-05 | Pixel gắn qua kết nối TLS của chính DroidDrive (không qua adb server): đọc thư mục, tạo, đổi tên, sửa, tải lên 20 MB (1,8 MB/s), xóa qua Finder | Điện thoại từ chối khóa lạ |
| P3-06, P3-07 | Cửa sổ "Connect via Wi-Fi…" bốn tab, đã nối vào menu; Pixel thật quét QR thành công (FR-12) | Nhập mã 6 số, nhập tay IP:cổng:mã trên máy thật (FR-13) |
| P3-08 | `WifiReconnector` trong nguồn Wi-Fi của app | FR-15 trên máy thật |
| P4-01 | Cửa sổ Devices, hướng dẫn bằng chữ và SF Symbols | Người dùng mới thử; ảnh hướng dẫn |
| P4-02 | Xong (FR-17) | |
| P4-03 | Huy hiệu cho bản "(Mac copy)" (FR-18) | |
| P4-04 | Cài đặt, chu kỳ làm mới theo máy, Remove Device xóa ổ, cache và ghép đôi Wi-Fi (FR-20) | Nút tạo khóa ADB mới |
| P4-05 | Giao diện chỉ tiếng Anh | |
| P4-06 | Số đo ở `spikes.md` | Liệt kê thư mục lớn qua Finder không đạt mục 9: fileproviderd mất khoảng 30 ms cho mỗi mục |
| P4-07 | `scripts/release.sh` (archive, ký Developer ID, notarize, staple, DMG) | Chạy với tài khoản trả phí; Sparkle và nơi đặt bản cập nhật chờ quyết định |
| P4-08 | Bảng FR trên emulator | Ma trận máy thật, macOS 13 và 15 |
