# Kết quả các bài thử giai đoạn 0

Tài liệu này ghi câu trả lời cho bốn câu hỏi có/không ở giai đoạn 0 của [`plan.md`](plan.md), những câu mà nếu trả lời "không" thì phải đổi thiết kế trong [`spec.md`](spec.md). Mỗi bài ghi: câu hỏi, cách thử, máy và phiên bản, kết quả, hệ quả cho thiết kế. Ngày thử: 14/11/2026.

Khác với kế hoạch ban đầu, S0-b và S0-c không làm thành chương trình bỏ đi. Code của hai bài này chính là các package của giai đoạn 1 (`AdbKit`, `ItemStore`, extension File Provider), nên được giữ lại. Bài nào cần điện thoại thật cắm USB thì chưa làm, vì máy thử không có điện thoại.

## Máy thử

| | |
|---|---|
| Mac | MacBook Pro Intel Core i7-9750H, 16 GB RAM, macOS 26.7.2 (25G332) |
| Công cụ | Xcode 26.6, Swift 6.3.3, XcodeGen, adb của platform-tools |
| Điện thoại | Android Emulator `Pixel_4_XL`, ảnh `android-35/google_apis/x86_64` (Android 15), không dùng máy thật |
| Ký | chứng chỉ "Apple Development" của Personal Team (`43FEB573SC`), ký tại máy, không có provisioning profile |

## Tóm tắt

| Mã | Câu hỏi | Trả lời | Hệ quả |
|---|---|---|---|
| S0-a | Mở được giao diện MTP bằng `IOUSBHost` khi `ptpcamerad` chạy? | **Chưa thử**: công cụ `droiddrive-usb` đã sẵn, cần điện thoại thật cắm cáp | Chặn P2-01 trở đi; ADB vẫn là đường chính |
| S0-b | Tự viết được bắt tay ADB tới `sync:` `LIST`? | **Có, qua TCP**. Phần USB (UsbKit) chưa thử | Giữ quyết định 4 (tự viết client ADB). Lớp giao thức không phụ thuộc đường truyền, USB chỉ thêm một `AdbPacketLink` |
| S0-c | File Provider replicated hiện trong Finder, đọc, ghi, đổi tên, hàng đợi khi mất kết nối? | **Có**, với một điều kiện: macOS 26 tạo domain ở trạng thái tắt, người dùng phải bật | Thêm bước "bật DroidDrive" vào hướng dẫn và vào menu (đã làm) |
| S0-d | FSKit gắn được hệ thống tệp không dựa trên thiết bị khối? | **Có trên giấy** (`FSGenericURLResource`, module FTP của Apple); bài thử chưa gắn được vì công tắc bật module không ăn | Quyết định có thay File Provider bằng FSKit hay không còn chờ số đo liệt kê |

## S0-b: client ADB tự viết

**Cách thử.** `droiddrive-cli` (target `DroidDriveCLI` trong `Packages/`) mở TCP tới adbd của emulator (`127.0.0.1:5555`, sau khi tắt adb server), gửi `CNXN`, ký `AUTH TOKEN` bằng `~/.android/adbkey`, mở `sync:` và `shell,v2,raw:`. Lặp lại qua adb server (`host:transport:<serial>`), là đường mà P1-08 cần.

**Kết quả.**

- Bắt tay, AUTH bằng chữ ký, `LIS2`/`STA2`/`LST2`, `RECV`, `SEND`, `shell,v2` đều chạy, cả trực tiếp lẫn qua adb server.
- Khóa công khai định dạng Android do code tự sinh trùng **từng byte** với `adb pubkey` (test `AdbKeyTests`).
- Đường hỏi "Cho phép gỡ lỗi USB?" (gửi `RSAPUBLICKEY`, chờ người bấm) chỉ thử với adbd giả trong test, vì emulator đã tin sẵn khóa của adb.
- Nhánh giao thức v1 (`LIST`, `STAT`, `shell:` không có v2) chạy được khi giấu các feature v2 khỏi emulator (test `LegacyProtocolTests`). Chưa thử trên máy Android cũ thật.

**Tốc độ, tệp 1 GB ngẫu nhiên, bản release, cùng emulator** (mục 9 của đặc tả yêu cầu ≥ 80% của `adb`):

| | push | pull |
|---|---|---|
| `adb` | 160–172 MB/s | 105–110 MB/s |
| DroidDrive qua adb server | 181–193 MB/s | 90–114 MB/s |
| DroidDrive kết nối trực tiếp | 174–177 MB/s | 94–111 MB/s |

SHA-256 khớp sau mỗi lượt sang và về, mtime giữ đúng tới giây (FR-09). Số đo trên emulator chỉ để so tương đối; điện thoại thật qua cáp USB phải đo lại ở P1-14.

**Liệt kê thư mục 10.000 tệp** qua adb server: trang đầu (500 mục) sau 0,13 giây, đủ cả thư mục sau 1,6 giây (mục tiêu ≤ 2 và ≤ 15 giây).

**Lỗi tìm thấy và đã sửa trong lúc thử:**

1. Bộ đọc luồng chép lại cả bộ đệm sau mỗi khúc 64 KB, độ phức tạp O(n²). Pull ban đầu chỉ đạt 63% tốc độ `adb`.
2. Mở dịch vụ qua adb server: phần dữ liệu tới cùng gói TCP với "OKAY" bị bỏ mất. Sync không dính, `shell:` thì có.
3. Ghi đè một tệp lớn bị báo hết chỗ, vì phép kiểm tra chỗ trống không trừ dung lượng tệp cũ.
4. Tín hiệu OKAY tới trong lúc đang gửi gói bị mất, làm luồng treo (race).
5. Hết giờ chờ bắt tay không hủy được lệnh đọc đang chờ, làm treo vô hạn.

**Chưa làm:** đường USB (`UsbKit`, P1-03), lưu khóa vào Keychain (CLI và test đang dùng `~/.android/adbkey` hoặc tệp PEM), tệp 6 GB (emulator chỉ có 3,3 GB trống).

## S0-c: File Provider replicated

**Cách thử.** App thanh menu (`App/`) tạo một domain cho mỗi bộ nhớ của emulator. Extension (`FileProvider/`) nói chuyện với emulator qua adb server. Mọi thao tác chạy từ Terminal trên đường dẫn `~/Library/CloudStorage/DroidDrive-…`, cùng đường mà Finder dùng, và được đối chiếu trên điện thoại bằng `adb shell`.

**Kết quả.**

| Việc | Kết quả |
|---|---|
| FR-03: mỗi bộ nhớ một ổ | Hai mục `sdk_gphone64_x86_64 · Bộ nhớ trong` và `· Thẻ SD 0000-0000` |
| FR-04/05: duyệt, mở tệp | Đạt |
| FR-06: tạo tệp và thư mục, đổi tên, di chuyển, sửa, xóa | Đạt, mỗi thao tác thấy được trên điện thoại sau vài giây |
| FR-08: tên tiếng Việt từ Mac (NFD) | Lên điện thoại ở dạng NFC (kiểm bằng `od -c`) |
| FR-10: rút kết nối, tệp đã tải vẫn mở được, sửa, kết nối lại | Bản sửa lên điện thoại sau 3 giây |
| FR-11: điện thoại thêm tệp | Hiện trên Mac trong chu kỳ làm mới 30 giây (đo được 18 giây) |
| Xung đột: Mac sửa bản cũ trong khi điện thoại đã đổi | Giữ bản của điện thoại; bản của Mac thành `phone (bản trên Mac).txt` (từ 14/11/2026 UI chỉ tiếng Anh, tên này thành `phone (Mac copy).txt`); Finder hiện cả hai |

**Điều phải biết, ảnh hưởng thiết kế:**

1. **macOS 26 tạo domain ở trạng thái "user-disabled".** Trước khi người dùng bật DroidDrive trong Cài đặt hệ thống → Chung → Mục đăng nhập & Tiện ích mở rộng → File Provider, mọi thao tác trong thư mục đều hết giờ chờ và extension không được khởi chạy. Không có API hay lệnh nào bật thay người dùng (`fileproviderctl` không có). Menu giờ phát hiện `userEnabled == false` và có nút mở đúng trang cài đặt. P4-01 cần ảnh hướng dẫn cho bước này.
2. **Thư mục tạo từ Mac không bao giờ được Finder liệt kê**, vì Finder đã biết nội dung của nó. Nếu làm mới chỉ dựa vào thư mục đã liệt kê thì tệp điện thoại thêm vào đó không bao giờ hiện. Đã sửa: thư mục tạo từ Mac được đánh dấu cần làm mới.
3. **Tạo tệp trùng tên với một tệp Finder chưa biết** (điện thoại vừa tạo): trả `filenameCollision` làm tệp kẹt lại ở Mac. Đã đổi: giữ cả hai, bản của Mac lên với tên xung đột; thư mục trùng tên thì gộp.
4. **Ghi thêm vào tệp chưa tải về** khiến macOS tải bản mới nhất trước rồi mới sửa, nên không phải xung đột. Xung đột chỉ xảy ra khi Mac giữ bản cũ đã tải về.
5. Ký tại máy bằng chứng chỉ Apple Development, không cần provisioning profile, là đủ để chạy extension và app group khi phát triển.

**Tạm thời, lệch kiến trúc:** extension đang tự mở kết nối tới adb server, thay vì đi qua app bằng XPC như mục 5.1 của đặc tả. Cách này chạy được vì adb server, không phải DroidDrive, giữ cổng USB. Khi có `UsbKit` (DroidDrive tự giữ USB), phải làm P1-11 (XPC) trước, vì chỉ một tiến trình được chiếm giao diện USB. Chỗ cần thay chỉ có `DomainContext.transport()`. **Đã làm tối 14/11/2026:** app giữ kết nối, extension gọi qua XPC; cách nối khác thiết kế ban đầu, xem mục 5.1 của đặc tả.

## Thử trên điện thoại thật qua Wi-Fi (tối 14/11/2026)

**Máy:** Pixel 4 XL, Android 13, 50 GB (đã dùng 37 GB), không có thẻ SD. Ghép đôi bằng `adb pair` của platform-tools (mã 6 số), sau đó adb server tự nối qua mDNS; DroidDrive thấy máy qua adb server, gắn một ổ "Pixel 4 XL · Internal storage". Mọi thao tác ghi đều nằm trong `/storage/emulated/0/DroidDriveTest`, đã xóa khi xong.

**Test tích hợp** (`DROIDDRIVE_TEST_ROOT=/storage/emulated/0/DroidDriveTest`): 7/8 đạt. Bài thư mục 10.000 tệp liệt kê đủ trong 8,3 giây (mục tiêu 15), nhưng trang đầu mất 2,27 giây (mục tiêu 2) trong lúc bài đo tốc độ đang chạy cùng và chia băng thông; cần đo lại riêng. Tạo 10.000 tệp bằng `xargs touch` trên điện thoại thật mất phần lớn thời gian của bài (cả bài 20 phút).

**Tốc độ qua Wi-Fi, tệp 100 MB, chạy riêng:**

| | DroidDrive | `adb` | Tỉ lệ |
|---|---|---|---|
| pull | 1,7 MB/s | 1,9 MB/s | 89% |
| push | 3,0 MB/s | 2,8 MB/s | 107% |

Mạng Wi-Fi ở đây chậm (2–3 MB/s với cả `adb`). Tệp 300 MB sang và về khớp SHA-256, giữ đúng mtime.

**Qua Finder:** tạo tệp và thư mục tên tiếng Việt (lên điện thoại ở dạng NFC), đổi tên, di chuyển, sửa, xóa cả thư mục đều đúng; tệp điện thoại tạo hiện trên Mac sau 4 giây; xung đột giữ bản của điện thoại và đẩy bản của Mac thành `tu-dien-thoai (Mac copy).txt`. Lúc này app đã chạy kiến trúc XPC.

**Lỗi tìm thấy:** bản `droiddrive-cli` build lúc 17:04 báo "thiết bị đóng luồng giữa chừng" khoảng 1/20 lần. Bản đó có trước lần sửa lỗi 2 ở trên (dữ liệu đến cùng gói TCP với "OKAY" của adb server bị bỏ mất); trên Wi-Fi chậm, kết quả lệnh shell thường đến cùng gói với "OKAY". Code hiện tại chạy 40/40 lần đúng. Lỗi này chỉ lộ ra trên mạng thật, emulator không tái hiện được.

**Ghép đôi bằng chính DroidDrive** (cửa sổ "Connect via Wi-Fi…", tab QR): người dùng quét mã bằng Pixel, ghép đôi thành công. DroidDrive tự nối qua TLS và gắn lại cùng ổ; menu ghi "Pixel 4 XL (ADB · Wi-Fi)". Qua Finder trên đường này: đọc thư mục, tạo thư mục và tệp tên tiếng Việt, đổi tên, sửa, tải lên 20 MB trong 11,4 giây (1,8 MB/s, ngang `adb` trên mạng này), xóa cả thư mục đều đạt, theo nhật ký truyền tệp và lần làm mới sau đó.

Quan sát, chưa kiểm kỹ: sau khi DroidDrive nối TLS, adb server mất điện thoại (`adb devices` trống) và `adb connect` tới đúng cổng điện thoại đang quảng bá báo "failed to connect". Có thể Android chỉ nhận một kết nối gỡ lỗi không dây mỗi lúc. Nếu đúng, người dùng Android Studio sẽ thấy DroidDrive và adb giành nhau điện thoại qua Wi-Fi; cần thử lại và ghi vào đặc tả.

## Số đo của app trên emulator (agent làm P4-06, Mac đang tải nặng, load average 4–138)

- **Tốc độ ở lớp truyền, 200 MB:** tải lên 30 và 96 MB/s so với `adb push` 28 và 26 MB/s; tải về 75 và 152 MB/s so với `adb pull` 83 và 97 MB/s. Qua Finder từ đầu đến cuối: lên 21–65 MB/s, về 42–60 MB/s.
- **Liệt kê thư mục mở lần đầu qua Finder:** 300 mục 10–11 giây, 1.000 mục 30 giây, 10.000 mục 401 giây. Extension trả mỗi trang 500 mục trong dưới 0,25 giây; thời gian là fileproviderd tạo tệp giữ chỗ cho từng mục, khoảng 30 ms một mục (3.803 việc như vậy xếp hàng). Tắt huy hiệu không đổi gì. Trong lúc đó, tải lên vào cùng ổ phải chờ.
- **Bộ nhớ:** extension 16–17 MB, app 40–55 MB. **CPU khi rảnh:** 0,96% với 3 ổ của 2 máy.
- **Bảng FR trên emulator:** FR-03, 05, 06 (mỗi thao tác 0,7–1,8 giây), 08, 09, 10 (với app tắt rồi mở lại: đẩy lên 2 giây sau), 11 (30,1 giây, đúng chu kỳ làm mới), 17, 18, 19, 20 đạt; FR-04 đủ nhưng chậm như trên.

## USB và MTP: mới thử với điện thoại giả

`UsbKit`, `MtpKit` và `droiddrive-usb` đã viết và test, nhưng chỉ với một điện thoại MTP giả trong bộ nhớ (theo cách Android MtpServer chạy ở những chỗ khác với chuẩn) và ống USB giả. Phần mở giao diện USB thật mới biên dịch. Đã chạy thật được phần chỉ đọc: `droiddrive-usb list` và `watch` liệt kê đúng 12 thiết bị USB của Mac này, và một test kiểm `UsbInterfaceOpener` từ chối mọi giao diện không phải Android (bàn phím, trackpad) trước khi gọi IOUSBHost.

Lệnh cho lần đầu cắm điện thoại thật (S0-a, P2-09):

```sh
cd Packages
swift run droiddrive-usb list
swift run droiddrive-usb mtp-info            # rồi chạy lại sau: killall ptpcamerad; thử cả --seize
swift run droiddrive-usb mtp-ls /storage/emulated/0/DCIM
swift run droiddrive-usb adb-info            # adb server phải không giữ giao diện ADB
```

## S0-d: FSKit với tài nguyên URL (đêm 14/11/2026, chưa xong)

**Câu hỏi.** FSKit trên macOS 26 có gắn được hệ thống tệp không dựa trên thiết bị khối không? Câu này được làm sớm vì liệt kê thư mục lớn qua File Provider không đạt mục 9 (fileproviderd mất khoảng 30 ms cho mỗi mục).

**Trên giấy: có.**

- SDK macOS 26 có `FSGenericURLResource` (một URL bất kỳ, khai báo scheme bằng `FSSupportedSchemes`) và `FSPathURLResource`, cả hai `API_AVAILABLE(macos(26.0))`.
- macOS 26.7 có sẵn `com.apple.fskit.ftp.appex`, gắn FTP theo đúng cách này: `FSSupportsGenericURLResources = true`, `FSSupportsBlockResources = false`, `FSSupportedSchemes = [ftp]`. Gắn bằng `mount -F -t <FSShortName> <url> <điểm gắn>`.

**Bài thử** nằm ở `spikes/fskit/` (project XcodeGen riêng): app chủ tối giản và extension `DroidSpikeFS` (`UnaryFileSystemExtension`, `FSUnaryFileSystem`, `FSVolume` chỉ đọc). Nó sinh trong bộ nhớ một thư mục `many/` có N tệp, gắn bằng `droidspike://test?files=10000`. Mã biên dịch được với SDK 26.5.

**Đã biết:**

- Quyền `com.apple.developer.fskit.fsmodule` cần provisioning profile: ký tại máy không profile bị Xcode từ chối ("requires a provisioning profile with the FSKit Module feature"). Personal Team miễn phí tạo được profile có quyền này (automatic signing).
- macOS nhận module (`pluginkit -m -p com.apple.fskit.fsmodule` liệt kê nó). Cài đặt hệ thống hiện nó dưới dòng tên app, mục "FSKit Modules", chứ không có mục "File System Extensions" riêng.
- `mount` báo "Module … is disabled!" cho tới khi người dùng bật. **Công tắc trong Cài đặt hệ thống không bật được**: bấm thì công tắc không đổi, kể cả sau khi chuyển app sang `~/Applications` trên ổ hệ thống và thoát hẳn Cài đặt. `pluginkit -e use` đánh dấu được extension nhưng FSKit vẫn báo tắt.
- FSKit lưu danh sách module được bật trong `~/Library/Group Containers/group.com.apple.fskit.settings/enabledModules.plist`; công tắc không ghi được gì vào đó. `fskitd` có chuỗi "Call fskit_agent to set enabled state".
- Gatekeeper từ chối bản ký Development (`spctl --assess`: rejected). Để loại trừ chữ ký, bản thử được ký **Developer ID** của team cá nhân `43FEB573SC` (Xcode tạo chứng chỉ quản lý trên đám mây khi export `developer-id`), **notarize** (Accepted), staple, cài vào `/Applications`; Gatekeeper chấp nhận ("Notarized Developer ID"), không còn `get-task-allow`. **Công tắc vẫn không bật được**, `enabledModules.plist` vẫn không có module. Vậy chữ ký không phải nguyên nhân.
- Log hệ thống (kể cả mức debug) không ghi gì từ `fskitd`, `fskit_agent` hay trang Cài đặt khi bấm công tắc. Giả thuyết còn lại: lỗi của Cài đặt hệ thống trên macOS 26.7.2 với module FSKit bên thứ ba, hoặc một khóa Info.plist còn thiếu. Người dùng đã tự thêm id module vào `enabledModules.plist` (bản cũ lưu ở `/tmp/enabledModules.bak`). `mount` vẫn báo "disabled" vì `fskit_agent` (chạy dưới tài khoản người dùng) giữ trạng thái trong bộ nhớ và không khởi động lại được: nó bỏ qua SIGTERM, còn `launchctl kickstart -k user/501/com.apple.fskit.fskit_agent` báo "Operation not permitted while System Integrity Protection is engaged". Bước kiểm tiếp theo: đăng xuất hoặc khởi động lại máy, rồi `mount -F -t droidspike 'droidspike://test?files=10000' /tmp/droidspike`.

**Chưa đo được** tốc độ liệt kê, vì chưa gắn được.

## S0-a và S0-d

Chưa có kết luận. Công cụ cho S0-a đã sẵn (mục trên). S0-a cần một điện thoại thật cắm USB ở chế độ "Truyền tệp", tốt nhất là cả Pixel lẫn Samsung (mục 1 của kế hoạch). S0-d xem mục riêng ở trên.
