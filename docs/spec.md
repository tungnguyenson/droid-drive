# Đặc tả: ứng dụng gắn điện thoại Android vào Finder trên Mac

Tài liệu này là đặc tả để làm lại một ứng dụng tương đương [MacDroid](https://www.macdroid.app/): một ứng dụng macOS gắn (mount) điện thoại Android thành một ổ đĩa trong Finder, để duyệt, mở, sửa, chép tệp qua lại như với ổ USB thường. Lý do cần nó: macOS không đọc được điện thoại Android qua cáp (Android dùng giao thức MTP, Mac chỉ hiểu PTP của máy ảnh), còn Android File Transfer của Google đã ngừng phát triển.

Mục tiêu: người đọc (người viết code, hoặc một agent) đọc xong biết phải làm những gì, theo thứ tự nào, mỗi phần xong khi nào. Phần 2 ghi lại MacDroid làm gì (kết quả tìm hiểu ngày 13/11/2026). Các phần sau đặc tả bản làm lại, tên tạm **DroidDrive**.

Cách làm, tóm gọn: một ứng dụng Swift chạy ở thanh menu, giữ kết nối với điện thoại qua hai đường (MTP qua USB, ADB qua USB hoặc Wi-Fi), và đưa tệp vào Finder bằng File Provider, cơ chế chính thức của Apple cho ổ đám mây (iCloud Drive, Dropbox, Google Drive đều dùng). Ràng buộc định hình thiết kế: không dùng kernel extension hay macFUSE, để người dùng không phải cài thêm gì hay hạ mức bảo mật của máy.

## 1. Thuật ngữ

| Thuật ngữ | Nghĩa |
|---|---|
| MTP (Media Transfer Protocol) | Giao thức truyền tệp qua USB mà Android bật khi người dùng chọn "Truyền tệp" trên điện thoại. Không cần bật gì thêm. Mở rộng từ PTP. |
| PTP (Picture Transfer Protocol) | Giao thức gốc cho máy ảnh. MTP là PTP cộng thêm các lệnh về thuộc tính tệp. |
| ADB (Android Debug Bridge) | Giao thức gỡ lỗi của Android. Cần bật "Gỡ lỗi USB" trong Tùy chọn nhà phát triển. Cho phép đọc ghi tệp nhanh hơn MTP và vào được thư mục hệ thống mà quyền shell đọc được. |
| Gỡ lỗi không dây (Wireless debugging) | ADB qua Wi-Fi, có từ Android 11. Lần đầu phải ghép đôi (pairing) bằng mã QR hoặc mã 6 số. |
| File Provider | Framework của Apple để một ứng dụng đưa một cây tệp "từ xa" vào Finder. Tệp nằm ở `~/Library/CloudStorage/`, hiện ở mục Locations trong thanh bên Finder. MacDroid gọi kiểu gắn này là "macOS Native Drive". |
| Domain (File Provider) | Một "ổ" trong Finder. DroidDrive tạo một domain cho mỗi bộ nhớ của mỗi thiết bị (bộ nhớ trong, thẻ SD). |
| FSKit | Framework của Apple (macOS 15.4 trở lên) để viết hệ thống tệp chạy ở user space, thay cho kernel extension và macFUSE. |
| macFUSE | Thư viện bên thứ ba để viết hệ thống tệp, cần cài kernel extension hoặc FSKit backend. DroidDrive không dùng. |
| Transport | Lớp nói chuyện với điện thoại (MTP hoặc ADB). Phía trên chỉ thấy một giao diện chung gồm liệt kê, đọc, ghi, xóa, đổi tên. |
| Helper | Tiến trình nền của DroidDrive giữ kết nối với điện thoại. Ở đây chính là ứng dụng thanh menu. |
| `ptpcamerad` | Tiến trình hệ thống của macOS tự chiếm thiết bị kiểu máy ảnh khi cắm vào. Nguyên nhân phổ biến nhất khiến công cụ MTP trên Mac "không thấy điện thoại". |

## 2. MacDroid làm gì (kết quả tìm hiểu)

Nguồn: trang chủ, trang giá, FAQ và lịch sử phiên bản của MacDroid (danh sách link ở phần 14). Phiên bản mới nhất lúc đọc: 2.10.1206, phát hành 30/06/2026, của Electronic Team, Inc.

### 2.1 Tính năng và gói bán

| | Free | PRO |
|---|---|---|
| Chép tệp từ điện thoại sang Mac, xem tệp trên điện thoại | Có | Có |
| Chép tệp từ Mac sang điện thoại | Không | Có |
| Sửa tệp ngay trên điện thoại, không cần chép về | Không | Có |
| USB và Wi-Fi | (trang giá chỉ ghi ở PRO) | Có |
| Thiết bị MTP khác: GoPro, Kindle, Garmin, Nintendo Switch, Oculus, Sony Walkman, Onyx Boox | | Có |
| Giá | 0 | 34 USD trọn đời (gạch giá 49), hoặc 19 USD/năm có dùng thử 7 ngày |

Một bản quyền PRO dùng trên tối đa 5 máy Mac, không giới hạn số điện thoại. Bán qua Paddle và cả Mac App Store (bản App Store không có kiểu gắn macFUSE).

### 2.2 Ba cách kết nối

- **MTP**: cắm cáp, chọn "Truyền tệp" trên điện thoại. Chạy với cả thiết bị không phải Android. FAQ thừa nhận hai lỗi: thư mục rất nhiều tệp có thể hiện rỗng (cách khắc phục duy nhất họ đưa ra là chuyển sang ADB), và không kết nối được khi ứng dụng khác đang giữ thiết bị (ví dụ iPhoto).
- **ADB**: bật Gỡ lỗi USB, bấm "Cho phép" trên điện thoại (có thể tích "Luôn cho phép từ máy tính này"). Họ quảng cáo là "mượt và nhanh hơn" và vào được thư mục hệ thống.
- **Wi-Fi**: vẫn là ADB nhưng qua mạng. Android 11 trở lên ghép đôi bằng mã QR, mã 6 số, hoặc nhập tay IP + cổng + mã. Android 10 trở xuống nhập IP. Cách thứ ba: cắm USB một lần, MacDroid tự chuyển sang Wi-Fi. Mac và điện thoại phải cùng mạng Wi-Fi.

### 2.3 Ba kiểu gắn ổ

| Kiểu | MacDroid mô tả | Cơ chế (suy luận của tôi, trang không ghi) |
|---|---|---|
| macOS Native Drive (khuyên dùng) | "cách gắn ổ đám mây gốc của macOS", có từ macOS 11.3, làm việc được khi mất kết nối, thay đổi được đẩy lên khi kết nối lại | File Provider, kiểu replicated |
| macFUSE Drive | cần cài macFUSE | macFUSE |
| Network Drive | không cần cài gì, nhưng nhiều thao tác cùng lúc thì danh sách tệp tải chậm hoặc ổ bị ngắt | server WebDAV hoặc SMB chạy trên máy, Finder gắn như ổ mạng |

### 2.4 Giao diện và cài đặt

- Biểu tượng trên thanh menu, cửa sổ danh sách thiết bị, nút Mount/Unmount cho từng thiết bị, nút "Connect via Wi-Fi".
- Cửa sổ Activity Log hiện các lượt truyền và tốc độ (thêm ở bản 2.5 và 2.8).
- Finder hiện biểu tượng trạng thái trên tệp: đang tải về, đang tải lên, chờ tải lên, lỗi (thường do hết chỗ trên điện thoại hoặc trên Mac, hoặc rớt kết nối).
- Cài đặt chung: mở cùng hệ thống, tự gắn khi mở ứng dụng, hiện ổ trên desktop, dùng tên ngắn trong thanh bên Finder, chọn thư mục cache (macOS 15+), thời gian giữ tệp cache, kéo thả là chép thay vì di chuyển, cho tài khoản khác trên máy thấy ổ (cần FUSE). Vài mục bị ẩn, giữ phím Option mới hiện.
- Cài đặt theo thiết bị: chu kỳ làm mới nội dung, kiểu gắn (ẩn), xóa thiết bị.
- Hỗ trợ AppleScript (từ 1.3), chip Apple (từ 1.4).

### 2.5 Điểm yếu của MacDroid mà bản làm lại nên làm tốt hơn

1. Thư mục lớn qua MTP không hiện được. Nguyên nhân có thể đoán: liệt kê từng tệp một (`GetObjectInfo` cho mỗi tệp) thay vì lấy theo lô. Xem 5.3.
2. Khi thiết bị bị ứng dụng khác chiếm, chỉ báo chung chung. Bản làm lại nên nói rõ tiến trình nào đang giữ và cách gỡ. Xem 5.7.
3. Lỗi bảng mã tên tệp khi dùng rsync. Với tên tệp tiếng Việt, chuẩn hóa Unicode là bắt buộc. Xem 5.6.
4. Ba kiểu gắn ổ với ba tập tính năng khác nhau, nhiều cài đặt chỉ áp dụng cho một kiểu. Bản làm lại chỉ có một kiểu.

## 3. Phạm vi

### 3.1 Làm

- Gắn bộ nhớ trong và thẻ SD của điện thoại Android vào Finder, đọc và ghi.
- Kết nối qua MTP (USB), ADB (USB), ADB qua Wi-Fi (Android 11+ ghép đôi, Android 10 trở xuống qua `tcpip`).
- Làm việc khi mất kết nối với các tệp đã tải về; thay đổi được đẩy lên khi kết nối lại.
- Thanh menu, cửa sổ thiết bị, cửa sổ nhật ký truyền tệp, cài đặt.
- Thiết bị MTP không phải Android (Kindle, GoPro…) ở mức "chạy được nếu thiết bị theo chuẩn MTP", không cam kết từng dòng máy.

### 3.2 Không làm (ở bản đầu)

- macFUSE, kernel extension, kiểu ổ mạng.
- Gói Free/PRO và thanh toán (xem mục Cần chốt).
- Root, đọc phân vùng hệ thống ngoài quyền của shell ADB.
- Sao lưu, đồng bộ hai chiều theo lịch, chiếu màn hình, tin nhắn.
- Windows, Linux.

## 4. Yêu cầu chức năng

Mỗi yêu cầu có tiêu chí nghiệm thu, viết sao cho kiểm được bằng tay hoặc bằng test.

| Mã | Yêu cầu | Nghiệm thu |
|---|---|---|
| FR-01 | Phát hiện thiết bị khi cắm cáp | Thiết bị hiện trong menu trong vòng 2 giây sau khi điện thoại ở chế độ "Truyền tệp" hoặc đã cho phép ADB |
| FR-02 | Chọn chế độ MTP hoặc ADB cho từng thiết bị, nhớ lựa chọn | Rút ra cắm lại, chế độ giữ nguyên. Nếu có cả hai, mặc định ADB (nhanh hơn, ít lỗi hơn) |
| FR-03 | Gắn mỗi bộ nhớ thành một ổ trong Finder | Bộ nhớ trong và thẻ SD hiện thành hai mục trong thanh bên, tên dạng "Pixel 8 · Internal storage" (thẻ SD: "Pixel 8 · SD card 1A2B-3C4D") |
| FR-04 | Duyệt thư mục | Thư mục 10.000 tệp hiện đủ qua cả MTP và ADB (đối chiếu với `adb shell ls \| wc -l`) |
| FR-05 | Mở tệp từ Finder | Nhấp đúp ảnh, PDF, video mở bằng ứng dụng mặc định; tệp được tải về khi mở |
| FR-06 | Chép, sửa, tạo, xóa, đổi tên, di chuyển tệp và thư mục | Mỗi thao tác làm trong Finder thấy được trên điện thoại (ứng dụng Files của Google) sau khi trạng thái tệp hết "đang tải lên" |
| FR-07 | Tệp lớn hơn 4 GB | Chép một video 6 GB sang và về, checksum SHA-256 khớp |
| FR-08 | Tên tệp Unicode | Tệp tên "Ảnh cưới Đà Lạt.jpg" tạo từ Mac hiện đúng trên điện thoại và ngược lại; không sinh hai bản trùng tên khác dạng chuẩn hóa |
| FR-09 | Giữ thời gian sửa đổi | Chép tệp sang điện thoại qua ADB, `stat` trên điện thoại cho đúng mtime gốc. MTP: ghi nhận nếu thiết bị không hỗ trợ |
| FR-10 | Làm việc khi mất kết nối | Rút cáp, tệp đã tải vẫn mở được; sửa một tệp, cắm lại, bản sửa được đẩy lên trong vòng 10 giây |
| FR-11 | Thấy thay đổi từ phía điện thoại | Chụp ảnh mới, ảnh hiện trong Finder trong khoảng chu kỳ làm mới (mặc định 30 giây; MTP có sự kiện thì ngay) |
| FR-12 | Kết nối Wi-Fi Android 11+ bằng mã QR | Quét QR trong mục Gỡ lỗi không dây, thiết bị hiện trong danh sách không cần gõ gì |
| FR-13 | Kết nối Wi-Fi bằng mã 6 số và nhập tay IP:cổng | Như trên |
| FR-14 | Kết nối Wi-Fi Android 10 trở xuống | Cắm USB một lần, bật "Chuyển sang Wi-Fi", rút cáp, ổ vẫn gắn |
| FR-15 | Tự kết nối lại thiết bị Wi-Fi đã ghép đôi | Tắt bật Wi-Fi điện thoại, thiết bị tự kết nối lại khi cùng mạng, không cần ghép đôi lại |
| FR-16 | Báo thiết bị bị chiếm | Khi `ptpcamerad` hoặc tiến trình khác giữ thiết bị, trạng thái ghi rõ tên tiến trình và có nút hướng dẫn gỡ (5.7) |
| FR-17 | Nhật ký truyền tệp | Cửa sổ liệt kê từng lượt: thời gian, tệp, chiều, dung lượng, tốc độ, kết quả; lọc theo thiết bị và trạng thái |
| FR-18 | Trạng thái tệp trong Finder | Tệp đang tải về, đang tải lên, chờ, lỗi có biểu tượng khác nhau |
| FR-19 | Tháo ổ | Nút Unmount gỡ domain khỏi Finder; lượt truyền đang chạy được hỏi xác nhận trước khi hủy |
| FR-20 | Xóa thiết bị | Xóa domain, cache và khóa ghép đôi Wi-Fi của thiết bị |

## 5. Kiến trúc

### 5.1 Các tiến trình

```
┌──────────────── DroidDrive.app (thanh menu, mở cùng hệ thống) ───────────────┐
│ UI (SwiftUI)        DeviceManager            TransferQueue / ActivityLog       │
│                      ├─ UsbWatcher (IOKit)                                     │
│                      ├─ WifiDiscovery (mDNS)                                    │
│                      └─ DeviceSession × N ── Transport: MtpTransport            │
│                                                       │ AdbTransport (USB/TCP) │
│ ExtensionLinker: nối vào service của từng domain ◄─────────────────────────┐  │
└────────────────────────────────────────────────────────────────────────────│──┘
                                                                             │ XPC
┌──────────── DroidDriveFileProvider.appex (do macOS khởi chạy) ─────────────┴──┐
│ NSFileProviderReplicatedExtension, một instance cho mỗi domain                 │
│ ItemStore (SQLite trong app group): identifier ↔ đường dẫn, metadata          │
└────────────────────────────────────────────────────────────────────────────────┘
```

Vì sao ứng dụng chính giữ kết nối mà không để extension giữ: giao diện USB chỉ một tiến trình được chiếm cùng lúc, còn macOS có thể dừng extension bất cứ lúc nào. Một nơi giữ phiên duy nhất, extension chỉ là khách.

**Cách nối XPC (làm ngày 14/11/2026).** Thiết kế ban đầu là một Mach service trong app group do ứng dụng mở. Cách này không chạy: một tiến trình không do launchd khởi chạy không đăng ký được Mach service (`NSXPCListener(machServiceName:)` báo "lookup error 3", bản sandbox thử nghiệm crash ngay khi mở). Vì vậy kết nối đi theo chiều ngược lại:

- Extension mở một `NSFileProviderServiceSource` cho mỗi domain, chỉ nhận tiến trình được quản lý domain đó. Phía sau là một `NSXPCListener` ẩn danh, kiểm chữ ký mã của bên nối vào (cùng bundle id và team).
- Ứng dụng nối vào bằng `NSFileProviderManager.service(named:for:)`, đưa ra một `DeviceHost` chỉ được đụng tới bộ nhớ của domain đó (mọi đường dẫn kiểm theo gốc bộ nhớ, từ chối `..`, không cho xóa hay đổi tên gốc).
- Khi extension cần điện thoại mà chưa có kết nối, nó gửi một Darwin notification riêng của domain và chờ tối đa 4 giây cho ứng dụng nối vào.
- Ứng dụng không chạy thì mọi lệnh báo `disconnected` (thành `serverUnreachable`) và trong 10 giây sau báo ngay, không chờ lại. Ứng dụng tắt vì thế giống như rút cáp: Finder giữ thay đổi và đẩy lên khi ứng dụng chạy lại (đo được 2 giây sau khi mở lại).
- Nối mất 20–130 ms. macOS chạy một tiến trình extension cho mỗi domain và khởi động lại chúng khoảng 30 giây một lần.

Mã: `Packages/Sources/DeviceService/` (`XPCProtocols`, `DeviceHost`, `HostLink`, `RemoteDeviceTransport`, `DeviceRegistry`, `DeviceSource`), `App/ExtensionLinker.swift`, `App/DeviceSources.swift`. Mỗi cách tìm điện thoại (adb server, ADB qua USB, MTP, Wi-Fi) là một `DeviceSource`; `DeviceRegistry` gộp chúng theo `ro.serialno` và chọn kết nối tốt nhất (ADB-USB, rồi ADB-Wi-Fi, rồi MTP, hoặc MTP trước nếu người dùng chọn).

Nếu ứng dụng chưa chạy, extension trả `NSFileProviderError.serverUnreachable`; Finder giữ thay đổi trong hàng đợi và thử lại sau. Vì vậy "Mở cùng hệ thống" mặc định bật, đăng ký bằng `SMAppService.mainApp`.

Truyền dữ liệu giữa extension và ứng dụng: extension tạo tệp tạm trong `NSFileProviderManager.temporaryDirectoryURL()`, gửi file descriptor qua XPC, ứng dụng ghi thẳng vào đó (hoặc đọc từ đó khi tải lên). Không đẩy byte qua XPC. Danh sách thư mục được kéo từng lô 500 mục; tiến độ và lệnh hủy đi trên cùng kết nối.

### 5.2 Giao diện transport chung

Mọi tầng phía trên chỉ biết giao diện này. MTP và ADB mỗi bên một bản cài đặt, test dùng một bản giả trong bộ nhớ.

```swift
protocol DeviceTransport: Sendable {
    var info: DeviceInfo { get }                       // hãng, model, serial, phiên bản Android
    func storages() async throws -> [StorageInfo]      // id, tên, dung lượng, còn trống
    func list(_ dir: RemotePath) -> AsyncThrowingStream<[RemoteEntry], Error>  // trả theo lô
    func stat(_ path: RemotePath) async throws -> RemoteEntry
    func read(_ path: RemotePath, to fd: FileHandle, range: Range<UInt64>?,
              progress: Progress) async throws
    func write(_ path: RemotePath, from fd: FileHandle, mtime: Date?,
               progress: Progress) async throws -> RemoteEntry
    func mkdir(_ path: RemotePath) async throws -> RemoteEntry
    func delete(_ path: RemotePath, recursive: Bool) async throws
    func rename(_ from: RemotePath, to: RemotePath) async throws -> RemoteEntry
    var changes: AsyncStream<ChangeHint> { get }       // MTP có sự kiện; ADB rỗng, dựa vào làm mới định kỳ
}
```

`RemoteEntry` gồm tên, đường dẫn, kiểu (tệp, thư mục, symlink), kích thước `UInt64`, mtime, và một khóa riêng của transport (handle MTP). Mọi lỗi được quy về một enum chung: `disconnected`, `busy(by: String?)`, `notFound`, `exists`, `noSpace`, `permissionDenied`, `unsupported`, `invalidName(String, reason:)` (tên vi phạm 5.6, kèm lý do để hiện cho người dùng), `protocolError(String)`.

Mỗi phiên chỉ chạy một lệnh MTP tại một thời điểm (MTP không cho chạy song song). ADB cho nhiều luồng song song trên một kết nối; giới hạn 4 luồng truyền cùng lúc mỗi thiết bị.

### 5.3 MTP

**Tìm thiết bị.** Theo dõi cắm rút bằng `IOServiceAddMatchingNotification`. Một giao diện USB là MTP nếu: class 0x06, subclass 0x01, protocol 0x01; hoặc class 0xFF có chuỗi mô tả giao diện là "MTP" (Android khi bật cùng lúc MTP và ADB). Mỗi giao diện có ba endpoint: bulk vào, bulk ra, interrupt vào (sự kiện).

**Truy cập USB.** Dùng `IOUSBHost` (`IOUSBHostInterface`, `IOUSBHostPipe`), mở giao diện độc quyền. Lỗi `kIOReturnExclusiveAccess` nghĩa là tiến trình khác đang giữ (5.7).

**Khung gói.** Mọi gói có tiêu đề 12 byte little-endian: độ dài (`UInt32`), loại (`UInt16`: 1 lệnh, 2 dữ liệu, 3 phản hồi, 4 sự kiện), mã (`UInt16`), transaction id (`UInt32`), rồi tối đa 5 tham số `UInt32`.

**Lệnh dùng đến:**

| Việc | Lệnh | Ghi chú |
|---|---|---|
| Mở phiên | `GetDeviceInfo` 0x1001, `OpenSession` 0x1002 | `DeviceInfo` cho biết các lệnh thiết bị hỗ trợ; kiểm tra trước khi dùng lệnh mở rộng |
| Bộ nhớ | `GetStorageIDs` 0x1004, `GetStorageInfo` 0x1005 | Mỗi storage id thành một domain |
| Liệt kê thư mục | `GetObjectPropList` 0x9805 với handle thư mục, depth 1 | **Lấy tên, kích thước 64 bit, ngày sửa, định dạng của cả thư mục trong một lệnh.** Chỉ khi thiết bị không hỗ trợ mới rơi về `GetObjectHandles` 0x1007 + `GetObjectInfo` 0x1008 từng tệp. Đây là chỗ sửa điểm yếu 1 của MacDroid |
| Đọc tệp | `GetPartialObject64` 0x95C1 (mở rộng Android), rơi về `GetObject` 0x1009 | Đọc theo khúc 1 MB để báo tiến độ và hủy được |
| Ghi tệp mới | `SendObjectInfo` 0x100C rồi `SendObject` 0x100D | Kích thước trong `ObjectInfo` là `UInt32`; tệp ≥ 4 GB ghi `0xFFFFFFFF` và đặt kích thước thật qua thuộc tính `ObjectSize` 0xDC04 |
| Sửa tệp có sẵn | `BeginEditObject` 0x95C4, `SendPartialObject` 0x95C2, `TruncateObject` 0x95C3, `EndEditObject` 0x95C5 | Mở rộng Android. Thiết bị không có thì tải lên một tệp tạm ẩn, xóa tệp cũ, rồi đổi tên tệp tạm, để tải lên hỏng giữa chừng không làm mất bản trên điện thoại; chỉ khi thiết bị cũng không đổi tên được mới xóa rồi ghi. Sửa bằng lệnh mở rộng thì điện thoại ghi giờ hiện tại, không giữ mtime của Mac (FR-09 chỉ đạt với tệp mới) |
| Tạo thư mục | `SendObjectInfo` với định dạng Association 0x3001 | |
| Xóa | `DeleteObject` 0x100B | |
| Đổi tên | `SetObjectPropValue` 0x9804, thuộc tính `ObjectFileName` 0xDC07 | |
| Di chuyển | `MoveObject` 0x1019 | Không có thì chép rồi xóa, báo người dùng là chậm |
| Sự kiện | interrupt endpoint: `ObjectAdded` 0x4002, `ObjectRemoved` 0x4003, `StoreAdded` 0x4004, `StoreRemoved` 0x4005, `ObjectInfoChanged` 0x4007 | Chuyển thành `ChangeHint` |

Handle MTP chỉ đáng tin trong một phiên. Khi kết nối lại, dựng lại bảng đường dẫn → handle theo nhu cầu, không coi handle là identifier lâu dài.

**Ghi nhận khi làm (14/11/2026, chưa kiểm trên máy thật).**

- Đường dẫn MTP dùng chung dạng với ADB: bộ nhớ trong là `/storage/emulated/0`, thẻ SD là `/storage/<nhãn>` khi nhãn có dạng `XXXX-XXXX`, ngược lại `/storage/<storage id hex>`. Nhờ vậy một máy nối qua MTP hay ADB vẫn là cùng một ổ, miễn Android báo mã thẻ SD làm nhãn.
- Tra đường dẫn theo đúng từng byte như ADB: dạng NFC và NFD là hai tệp khác nhau trên điện thoại. Ngày giờ MTP không có múi giờ; đọc và ghi theo giờ địa phương của Mac, tức là giả định điện thoại và Mac cùng múi giờ.
- Sự kiện xóa một đối tượng chưa từng duyệt tới thành `ChangeHint.changed(root)`, nghĩa là "có gì đó đổi, không rõ ở đâu": phía File Provider phải làm mới cả cây.
- Android để MTP ở class FF/FF/00 với chuỗi giao diện "MTP", PTP ở 6/1/1, ADB ở FF/42/01.
- Hủy một lần truyền phải chạy lệnh hủy PTP trong một task riêng (chạy trong task đã bị hủy thì chính các lần truyền USB của lệnh hủy cũng bị dừng ngay), và sau đó bỏ phần dữ liệu IN còn sót (khoảng 100 ms).
- IOUSBHost không có overlay Swift: các hàm có tên `__ioService:`, `__abort(with:)`, `__send(…)`; `kIOMessageServiceIsTerminated` và `kUSBHostReturnPipeStalled` không được import nên phải tự khai báo giá trị.
- Mỗi giao diện USB có thuộc tính `UsbExclusiveOwner` cho biết ai đang giữ: driver kernel hiện tên class, tiến trình người dùng hiện dạng `"pid N, tên"`. Đây là cách DroidDrive biết `ptpcamerad` hay MacDroid đang giữ điện thoại (mục 5.7).

**Phương án dự phòng:** nếu tự viết trên `IOUSBHost` gặp vướng ở bước thử nghiệm, dùng `libmtp` + `libusb` (LGPL 2.1, liên kết động). Tham khảo thêm OpenMTP (MIT, dùng thư viện Go `kalam`).

### 5.4 ADB

DroidDrive tự viết client ADB bằng Swift, không gọi binary `adb`. Tài liệu giao thức nằm trong mã nguồn AOSP: `packages/modules/adb/protocol.txt` và `SYNC.TXT`.

**Tìm thiết bị qua USB.** Giao diện class 0xFF, subclass 0x42, protocol 0x01, hai endpoint bulk.

**Tôn trọng adb server đang chạy.** Nếu người dùng có Android Studio, `adb` server của họ (cổng 5037 trên máy) đã chiếm giao diện USB. Khi đó DroidDrive không tranh, mà nói chuyện qua server đó: gửi `host:transport:<serial>` rồi `sync:` như một client adb thường. Có server thì dùng server, không có thì tự mở USB. Người dùng không phải biết điều này.

**Một điện thoại, một danh tính.** adb đặt tên cho kết nối, không cho điện thoại. Cùng một máy, qua USB là `R5CT20ABCDE`, qua Wi-Fi là `192.168.1.23:41234` (cổng đổi mỗi lần bật lại Gỡ lỗi không dây), qua mDNS là `adb-R5CT20ABCDE-…._adb-tls-connect._tcp`. Vì vậy ổ trong Finder đặt tên theo `ro.serialno` của điện thoại (máy không báo serial thì dùng serial của adb), và mọi kết nối cùng `ro.serialno` được gộp thành một dòng trong menu, ưu tiên USB. Trước khi ghi, extension kiểm lại `ro.serialno` của kết nối với serial của ổ. Hai máy khác nhau báo cùng serial (có máy rẻ để `0123456789ABCDEF`) được nhận ra nhờ `android_id` khác nhau: khi đó không gắn máy nào và menu báo "Trùng serial".

**Bắt tay.** Mỗi gói có tiêu đề 24 byte: command, arg0, arg1, độ dài dữ liệu, checksum, magic (= command XOR 0xFFFFFFFF). Lệnh: `CNXN`, `AUTH`, `OPEN`, `OKAY`, `WRTE`, `CLSE`, `STLS`. Gửi `CNXN` phiên bản 0x01000001, max data 1 MB, banner `host::features=shell_v2,cmd,stat_v2,ls_v2,fixed_push_mkdir,…`. Khi thiết bị đáp phiên bản ≥ 0x01000001 thì gửi checksum 0, như `adb`. Mỗi luồng chỉ có một `WRTE` chưa được `OKAY` theo mỗi chiều, và DroidDrive chỉ `OKAY` một `WRTE` của thiết bị khi đã đọc xong nó, để đĩa chậm thì điện thoại tự chậm theo thay vì dồn vào bộ nhớ.

**Xác thực.** Sinh một cặp khóa RSA 2048 lần đầu chạy, lưu trong Keychain. Thiết bị gửi `AUTH` loại TOKEN; ký token, gửi lại loại SIGNATURE. Thiết bị chưa biết khóa thì gửi khóa công khai (loại RSAPUBLICKEY, định dạng `RSAPublicKey` riêng của Android, base64, kèm tên `droiddrive@<hostname>`); điện thoại hiện hộp thoại "Cho phép gỡ lỗi USB?". UI hiện hướng dẫn "Mở khóa điện thoại và bấm Cho phép".

**Thao tác tệp:**

| Việc | Cách |
|---|---|
| Liệt kê | dịch vụ `sync:`, lệnh `LIS2` (kích thước 64 bit), rơi về `LIST` nếu thiết bị không có `ls_v2` |
| Stat | `STA2`, rơi về `STAT` |
| Đọc cả tệp | `RECV` → các khúc `DATA` → `DONE`. `RCV2` chỉ thêm nén, chưa dùng; `RECV` không giới hạn 4 GB vì dữ liệu chảy theo khúc |
| Đọc một khoảng | `exec:dd if=<path> bs=1M skip=… count=…` (luồng nhị phân sạch, khác `shell:`). Chỉ cần khi có FSKit (5.5) |
| Ghi | `SEND` với `<path>,<mode>`, khúc `DATA` tối đa 64 KB (nhiều khúc gộp vào một `WRTE`), kết thúc `DONE <mtime>` (giữ được mtime). `SND2` chỉ thêm nén, chưa dùng |
| Tạo thư mục, xóa, đổi tên | `shell,v2:` chạy `mkdir -p`, `rm -rf`, `mv`; đọc mã thoát |
| Bộ nhớ | `shell:` chạy `df` và liệt kê `/storage`; bộ nhớ trong là `/storage/emulated/0`, thẻ SD là `/storage/XXXX-XXXX` |

**An toàn khi gọi shell:** đường dẫn luôn bọc trong nháy đơn và thoát mọi nháy đơn bên trong (`'` → `'\''`), luôn có `--` trước đường dẫn. Tên tệp đến từ người dùng và từ điện thoại; một tệp tên `a'; rm -rf /sdcard; '` không được chạy thành lệnh. Có test riêng cho việc này.

**Wi-Fi:**

- **Android 10 trở xuống, hoặc "chuyển sang Wi-Fi" khi đang cắm cáp:** qua USB gửi dịch vụ `tcpip:5555`, đọc IP bằng `shell:ip route`, rồi mở TCP tới `<ip>:5555`. Nhớ IP và serial để tự kết nối lại.
- **Android 11 trở lên, ghép đôi:** điện thoại quảng bá dịch vụ mDNS `_adb-tls-pairing._tcp`. Giao thức ghép đôi là SPAKE2 (trao đổi khóa dựa trên mật khẩu, mật khẩu là mã 6 số) chạy trên TLS; xong thì hai bên trao chứng chỉ, điện thoại lưu chứng chỉ của DroidDrive. SPAKE2 lấy từ BoringSSL (`include/openssl/curve25519.h`), đóng gói thành một module C nhỏ.
- **Mã QR:** DroidDrive sinh chuỗi `WIFI:T:ADB;S:<random-service-name>;P:<random-password>;;` rồi vẽ QR. Điện thoại quét xong quảng bá `_adb-tls-pairing._tcp` với đúng tên dịch vụ đó; DroidDrive tìm thấy qua `NWBrowser` và ghép đôi bằng mật khẩu trong QR.
- **Kết nối sau ghép đôi:** điện thoại quảng bá `_adb-tls-connect._tcp`. Gửi `CNXN`, điện thoại đáp `STLS`, hai bên nâng lên TLS 1.3 với chứng chỉ tự ký từ khóa RSA ở trên (`sec_protocol_options_set_local_identity`), rồi bắt tay ADB như thường.
- **Tự kết nối lại:** khi thấy `_adb-tls-connect._tcp` của một thiết bị đã ghép đôi thì tự kết nối và gắn lại ổ.

**Ghi nhận khi làm Wi-Fi (14/11/2026).** Ghép đôi đã chạy với emulator và với `adb pair` thật (cả hai chiều); kết nối TLS đã chạy với adbd của emulator.

- Network.framework không nâng một kết nối TCP đang mở lên TLS được. Vì vậy kết nối được dựng sẵn là TLS chồng trên một `NWProtocolFramer` nhỏ chồng trên TCP: framer giữ TLS lại, tự chuyển `CNXN`/`STLS` dạng thường, rồi nhường đường.
- Chi tiết byte của AOSP dễ sai: tên SPAKE2 có cả ký tự NUL ở cuối (`"adb pair client\0"`); nhãn exporter TLS là 10 byte `"adb-label\0"`; độ dài trong tiêu đề gói là big-endian; nonce AES-GCM là bộ đếm 8 byte little-endian đệm 0 thành 12 byte, mỗi chiều một bộ đếm; PeerInfo của điện thoại là GUID của máy, cũng là tên dịch vụ `_adb-tls-connect._tcp`.
- macOS không có hàm công khai ghép một `SecKey` với chứng chỉ trong bộ nhớ. DroidDrive dựng một gói PKCS#12 rồi import: Apple bỏ qua khóa không mã hóa và từ chối gói không có MAC, nên khóa mã hóa PBES2/AES-256 và MAC là HMAC-SHA256. Trên macOS 13–14 việc import để lại một bản identity "DroidDrive ADB TLS" trong login keychain (chưa thử, máy thử chạy macOS 26).
- BoringSSL chuyển sang C++ từ cuối 2024; `CSpake2` lấy từ tag 0.20240913.0, bản cuối còn viết bằng C.
- Emulator có `ro.adb.secure=0` nên nhận cả khóa lạ; trường hợp điện thoại từ chối khóa chưa thử được.

### 5.5 Đưa tệp vào Finder

**Bản đầu: File Provider, kiểu replicated** (`NSFileProviderReplicatedExtension`). Lý do: không cần cài thêm gì, chạy được cả ngoài và trong App Store, có sẵn hàng đợi khi mất kết nối, biểu tượng trạng thái và tiến độ trong Finder.

**Identifier ổn định.** File Provider yêu cầu identifier của một item không đổi khi đổi tên hay di chuyển. Cả MTP handle lẫn đường dẫn đều không đạt điều đó. Vì vậy mỗi domain có một bảng SQLite `items(id TEXT PRIMARY KEY, parent_id, name, path, kind, size, mtime, version, transport_key)`; `id` là UUID sinh lần đầu thấy item. Đổi tên cập nhật `path`, giữ `id`. Item gốc dùng `NSFileProviderItemIdentifier.rootContainer`.

**Version của item** (dùng để phát hiện xung đột) = `size` + `mtime` gộp lại. Khi tải lên mà version trên điện thoại khác version Finder đang giữ thì có xung đột: giữ cả hai, đổi tên bản của Mac thành "Name (Mac copy).ext" (tên đó cũng có rồi thì "Name (Mac copy 2).ext"…). Tạo tệp mà điện thoại đã có tệp cùng tên Finder chưa biết cũng là xung đột, xử lý như trên; trùng tên thư mục thì gộp vào thư mục có sẵn.

**Ánh xạ thao tác:**

| File Provider gọi | DroidDrive làm |
|---|---|
| `enumerator(for:)` → `enumerateItems` | `transport.list`, trả theo trang 500 item để Finder hiện dần, ghi vào ItemStore |
| `enumerateChanges` (working set) | So ItemStore với lần liệt kê gần nhất của các thư mục đang mở; trả item đổi và bị xóa |
| `fetchContents` | `transport.read` vào tệp tạm, trả URL |
| `createItem` | `mkdir` hoặc `write` |
| `modifyItem` | Đổi nội dung → `write`; đổi tên hoặc cha → `rename`; đổi mtime → ghi lại mtime nếu transport hỗ trợ |
| `deleteItem` | `delete(recursive: true)` |
| Mất kết nối giữa chừng | Trả `serverUnreachable`; macOS giữ thao tác và gọi lại sau khi DroidDrive báo `signalErrorResolved` lúc kết nối lại |

**Làm mới.** Mỗi thiết bị có chu kỳ làm mới (mặc định 30 giây, chọn 10 giây, 1, 5 phút, hoặc tắt). Đến chu kỳ, hoặc khi có sự kiện MTP, gọi `NSFileProviderManager.signalEnumerator(for: .workingSet)`. Chỉ liệt kê lại các thư mục Finder đã mở, cộng các thư mục tạo từ Mac (Finder không bao giờ liệt kê những thư mục này), không quét toàn bộ điện thoại. Khi thiết bị vừa kết nối lại thì báo ngay (`signalErrorResolved` rồi `signalEnumerator`), không chờ chu kỳ, để đạt FR-10.

**Bật ổ.** Trên macOS 26 (thử 14/11/2026, xem `spikes.md`), domain mới tạo ở trạng thái tắt cho tới khi người dùng bật DroidDrive trong Cài đặt hệ thống → Chung → Mục đăng nhập & Tiện ích mở rộng → File Provider. Trong lúc đó mọi thao tác trong thư mục đều hết giờ chờ. App đọc `NSFileProviderDomain.userEnabled`, và khi domain đang tắt thì thay menu bằng hướng dẫn kèm nút mở trang cài đặt đó.

**Tháo ổ và mất kết nối.** Rút cáp: domain giữ nguyên, tệp đã tải vẫn mở được (FR-10). Unmount và Remove Device dùng `NSFileProviderManager.remove(domain, mode: .preserveDirtyUserData)`, hỏi trước nếu đang truyền tệp. Ghi nhận ngày 14/11/2026: ở cả hai chế độ giữ dữ liệu, macOS để lại một thư mục "<tên ổ> (ngày giờ)" chứa các tệp tạo từ Mac, kể cả tệp đã đẩy lên, và ứng dụng sandbox không được xóa thư mục đó. Gọi `NSFileProviderManager.add` với identifier đã có thì đổi tên ổ, dùng để đổi tên ổ do bản cũ đặt.

**Trạng thái trong Finder.** Finder tự vẽ biểu tượng đám mây cho trạng thái chưa tải, đang tải, chờ tải lên, lỗi tải lên. Nếu cần biểu tượng riêng như MacDroid thì dùng decoration của File Provider (`NSFileProviderDecorations` trong Info.plist); kiểm tra phiên bản macOS hỗ trợ khi làm.

**Giới hạn của File Provider, cần biết trước:** mở tệp là tải cả tệp về. Xem một video 10 GB nghĩa là chờ chép 10 GB. Và ổ nằm ở `~/Library/CloudStorage/DroidDrive-<domain-name>`, không phải `/Volumes/`. Hai điều này là lý do có giai đoạn FSKit.

**Giai đoạn sau: FSKit** (macOS 15.4 trở lên). Một `FSUnaryFileSystem` cho mỗi bộ nhớ, gắn vào `/Volumes/<volume-name>`, đọc theo khoảng (MTP `GetPartialObject64`, ADB `exec:dd`), nên phát video không cần chép trước. Rủi ro: bản FSKit đầu tiên hướng tới hệ thống tệp trên thiết bị khối; cần một bước thử nghiệm xác nhận phiên bản macOS hiện tại có kiểu tài nguyên không phải thiết bị khối (theo URL hoặc đường dẫn) trước khi cam kết. Người dùng phải bật extension trong Cài đặt hệ thống → Chung → Mục đăng nhập & Tiện ích mở rộng → Tiện ích mở rộng hệ thống tệp.

### 5.6 Tên tệp, thời gian, dung lượng

- **Chuẩn hóa Unicode.** macOS có thể đưa tên tệp ở dạng NFD (dấu tách rời), Android lưu đúng byte nhận được. Tên gửi xuống điện thoại luôn chuyển sang NFC. Khi so khớp tên (tìm trùng, xung đột), so theo NFC. Thiếu bước này, "Đà Lạt.jpg" từ Mac thành một tệp khác với "Đà Lạt.jpg" chụp trên điện thoại. Ngược lại, tên đọc từ điện thoại giữ nguyên byte (một ứng dụng Android có thể đã tạo tên dạng NFD), vì phải dùng đúng byte đó để gọi lại tệp. Lưu ý khi viết code: `String ==` của Swift so theo tương đương chính tắc, NFC và NFD bằng nhau, nên kiểm byte phải so `.utf8`.
- **Ký tự Android không cho phép** trong tên tệp trên bộ nhớ chung (`"*/:<>?\|`): từ chối với lỗi rõ ràng, không tự đổi tên.
- **Kích thước** luôn `UInt64`. MTP dùng thuộc tính `ObjectSize`, ADB dùng `LIS2`/`STA2`.
- **Hết chỗ:** kiểm tra dung lượng trống trước khi ghi tệp lớn hơn 100 MB, báo lỗi `noSpace` sớm thay vì hỏng giữa chừng. Khi ghi đè, chỉ phần lớn thêm so với tệp cũ mới cần chỗ.

### 5.7 Thiết bị bị tiến trình khác chiếm

Khi mở giao diện USB nhận `kIOReturnExclusiveAccess`:

1. Tìm tiến trình đang giữ: duyệt cây IORegistry của thiết bị, đọc thuộc tính client của giao diện (`IOUserClientCreator` có dạng `pid 2100, ptpcamerad`).
2. Hiện trạng thái "Bị chiếm bởi <process-name>" và gợi ý theo từng trường hợp:
   - `ptpcamerad`: giải thích đây là dịch vụ ảnh của macOS, có nút "Thử lại" kèm lệnh dừng tiến trình (`killall ptpcamerad`, tiến trình chạy dưới tài khoản người dùng); nếu nó tự chiếm lại, gợi ý chuyển sang ADB.
   - Android File Transfer, Smart Switch, OpenMTP, adb server của Android Studio (với ADB đã xử lý ở 5.4): bảo người dùng thoát ứng dụng đó.
3. Thử lại tự động mỗi 3 giây trong 30 giây.

Hành vi của `ptpcamerad` trên macOS 26 chưa được xác minh; đây là việc đầu tiên của giai đoạn thử nghiệm (phần 11).

## 6. Giao diện

**Thanh menu (luôn có).** Biểu tượng điện thoại; có chấm xanh khi có thiết bị đang gắn, vòng xoay khi đang truyền. Menu:

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

**Cửa sổ Thiết bị.** Thanh bên liệt kê thiết bị (đã từng kết nối, mờ nếu đang vắng). Khung chính: model, phiên bản Android, kiểu kết nối, từng bộ nhớ với thanh dung lượng, chọn chế độ MTP/ADB, nút Gắn/Tháo, chu kỳ làm mới, Xóa thiết bị. Khi điện thoại cắm vào mà chưa bật "Truyền tệp" hay chưa cho phép ADB, khung chính là hướng dẫn từng bước có hình, không phải thông báo lỗi.

**Kết nối qua Wi-Fi (sheet).** Bốn tab: Mã QR (mặc định), Mã ghép đôi, Nhập tay (IP, cổng, mã), Android 10 trở xuống (IP). Tab Mã ghép đôi tự liệt kê các điện thoại đang quảng bá `_adb-tls-pairing._tcp`, người dùng chỉ chọn và gõ 6 số.

**Nhật ký truyền tệp.** Bảng: thời gian, thiết bị, tệp, chiều (↓ về Mac, ↑ lên điện thoại), dung lượng, tốc độ trung bình, kết quả. Lọc theo thiết bị và kết quả, nút xóa nhật ký. Giữ 7 ngày.

**Ngôn ngữ.** Giao diện chỉ có tiếng Anh, kể cả tên ổ, tên bản xung đột và thông báo lỗi (người dùng chốt ngày 14/11/2026). Tài liệu trong repo vẫn viết tiếng Việt.

## 7. Cài đặt

| Mục | Mặc định | Ghi chú |
|---|---|---|
| Mở cùng hệ thống | Bật | `SMAppService.mainApp` |
| Tự gắn khi thiết bị kết nối | Bật | |
| Chế độ ưu tiên khi có cả MTP và ADB | ADB | |
| Chu kỳ làm mới mặc định | 30 giây | Ghi đè được theo thiết bị |
| Thời gian giữ tệp đã tải khi không dùng | Để macOS tự quản | File Provider tự dọn khi thiếu chỗ; thêm nút "Giải phóng dung lượng" để dọn ngay |
| Hiện thông báo khi truyền xong tệp lớn hơn | 500 MB | |
| Khóa ghép đôi | | Nút "Tạo khóa ADB mới" (điện thoại sẽ hỏi cho phép lại) |

Không có mục ẩn sau phím Option.

## 8. Quyền, entitlement, phân phối

| Cần | Vì sao |
|---|---|
| App Sandbox + `com.apple.security.device.usb` | Mở thiết bị USB |
| `com.apple.security.network.client` và `network.server` | ADB qua TCP; server cho bước ghép đôi |
| `NSLocalNetworkUsageDescription` + `NSBonjourServices` gồm `_adb-tls-pairing._tcp`, `_adb-tls-connect._tcp`, `_adb._tcp` | Quyền mạng cục bộ (từ macOS 15 bắt buộc); MacDroid bản 2.3 cũng phải thêm bước kiểm tra quyền này |
| App group `<TEAMID>.com.droiddrive` | Chia sẻ ItemStore và Mach service XPC giữa app và extension |
| Keychain access group | Khóa RSA của ADB |

Phân phối bản đầu: Developer ID, notarize, cập nhật qua Sparkle. Mọi thứ trên đều tương thích Mac App Store nên có thể đưa lên sau.

macOS tối thiểu: 13 (Ventura). Chip Apple và Intel (universal binary).

## 9. Hiệu năng

Đo tương đối với công cụ chuẩn trên cùng máy, cùng cáp, để con số không phụ thuộc phần cứng.

| Chỉ số | Mục tiêu |
|---|---|
| Tốc độ ADB qua USB, tệp 1 GB | ≥ 80% tốc độ `adb push` / `adb pull` |
| Tốc độ MTP qua USB | ≥ 80% tốc độ OpenMTP hoặc MacDroid trên cùng thiết bị |
| Liệt kê thư mục 1.000 tệp | ≤ 1,5 giây (ADB), ≤ 3 giây (MTP có `GetObjectPropList`) |
| Liệt kê thư mục 10.000 tệp | Trang đầu ≤ 2 giây, đủ cả thư mục ≤ 15 giây |
| Bộ nhớ của app khi rảnh | ≤ 150 MB |
| CPU khi rảnh, có 2 thiết bị gắn | ≤ 1% trung bình |

Đo ngày 14/11/2026 (chi tiết ở `spikes.md`): bộ nhớ extension 16–17 MB, ứng dụng 40–55 MB; CPU ứng dụng 0,96% khi rảnh với 3 ổ của 2 máy; tốc độ đạt ở cả emulator và Pixel qua Wi-Fi. **Liệt kê qua Finder không đạt**: thư mục 1.000 tệp mất 30 giây lần đầu mở, dù extension trả mỗi trang 500 mục trong dưới 0,25 giây. Thời gian nằm ở fileproviderd tạo một tệp giữ chỗ cho mỗi mục, khoảng 30 ms một mục trên máy thử. Với File Provider replicated, mục tiêu 1,5 và 15 giây không đạt được; đây là thêm một lý do cho FSKit ở giai đoạn 5.

## 10. Kiểm thử

- **Unit test:** mã hóa và giải mã gói MTP, ADB, sync; ký AUTH; chuẩn hóa tên; thoát đường dẫn cho shell (gồm các tên tệp độc hại); ItemStore đổi tên và di chuyển giữ identifier.
- **Test tích hợp với transport giả:** một `DeviceTransport` trong bộ nhớ, chạy toàn bộ luồng File Provider (liệt kê, tải, sửa, mất kết nối giữa chừng, xung đột).
- **ADB với Android Emulator** qua TCP, chạy được trên CI macOS: push, pull, tệp 5 GB, 10.000 tệp, tên tiếng Việt.
- **Thiết bị thật** (MTP và ADB qua USB không giả lập được): ma trận tối thiểu Pixel (Android 16), Samsung (One UI, Android 14 trở lên), Xiaomi, một máy Android 10, một Kindle. Mỗi bản phát hành chạy bảng FR-01 → FR-20 bằng tay trên ma trận này.
- **macOS:** 13, 15, 26.

## 11. Lộ trình

Mỗi giai đoạn xong khi tiêu chí ở cột cuối đạt.

| Giai đoạn | Nội dung | Xong khi |
|---|---|---|
| 0. Thử nghiệm | (a) mở giao diện MTP bằng `IOUSBHost` trên macOS 26 khi `ptpcamerad` chạy; (b) bắt tay ADB qua USB tới `sync:` `LIST`; (c) File Provider replicated với transport giả hiện trong Finder; (d) FSKit có gắn được hệ thống tệp không dựa trên thiết bị khối không | Có câu trả lời có/không cho cả bốn, ghi vào `docs/spikes.md`. (a) thất bại thì chuyển sang `libmtp` |
| 1. MVP ADB | ADB qua USB, File Provider đọc ghi đủ, menu thanh trên cùng, tên Unicode, tệp > 4 GB | FR-01, 03 → 10, 19 đạt trên Pixel và Samsung |
| 2. MTP | MtpTransport, xử lý thiết bị bị chiếm, sự kiện MTP | FR-02, 11, 16 đạt; thư mục 10.000 tệp qua MTP hiện đủ |
| 3. Wi-Fi | `tcpip` cho Android ≤ 10, ghép đôi SPAKE2, QR, tự kết nối lại | FR-12 → 15 đạt |
| 4. Hoàn thiện | Nhật ký truyền tệp, cài đặt, hướng dẫn có hình, notarize, Sparkle | FR-17, 18, 20 đạt; bản notarized cài trên một máy sạch chạy được |
| 5. Tùy chọn | FSKit (nếu thử nghiệm 0d đạt), App Intents cho Shortcuts, Mac App Store, gói trả phí | Theo quyết định lúc đó |

## 12. Rủi ro

| Rủi ro | Ảnh hưởng | Cách giảm |
|---|---|---|
| `ptpcamerad` chiếm giao diện MTP và tự chiếm lại sau khi bị dừng | MTP không dùng được trên một số máy | Thử nghiệm 0a; ADB là đường chính, MTP là đường phụ |
| Hãng điện thoại sửa MTP khác chuẩn (thiếu `GetObjectPropList`, thiếu lệnh mở rộng Android) | Chậm hoặc thiếu thao tác | Kiểm tra `DeviceInfo` và có đường rơi về cho mọi lệnh mở rộng |
| Ghép đôi Wi-Fi (SPAKE2 + TLS) khó làm đúng | Giai đoạn 3 kéo dài | Đối chiếu với mã AOSP `pairing_auth` và `pairing_connection`, và bản TypeScript của Tango (ya-webadb) |
| File Provider tải cả tệp mới mở được | Xem video lớn chậm | Ghi rõ trong hướng dẫn; FSKit ở giai đoạn 5 |
| Android chặn `Android/data` và `Android/obb` với shell ADB ở bản mới | Một số thư mục hiện rỗng | Hiện thư mục với chú thích "Android không cho phép truy cập", không báo lỗi |
| Lỗi đồng bộ làm mất dữ liệu trên điện thoại | Nghiêm trọng | Xóa và ghi đè chỉ chạy khi version khớp; xung đột thì giữ cả hai bản; test xung đột trong bộ test tích hợp |

## 13. Quyết định đã chốt

Người dùng đồng ý toàn bộ đề xuất ngày 13/11/2026. Kế hoạch thực hiện chi tiết nằm ở [`plan.md`](plan.md).

| # | Quyết định | Đã chốt |
|---|---|---|
| 1 | Cách đưa tệp vào Finder ở bản đầu | Chỉ File Provider (replicated). FSKit để giai đoạn 5, chỉ làm nếu thử nghiệm 0d đạt. Không làm macFUSE, không làm ổ mạng |
| 2 | macOS tối thiểu | macOS 13 (Ventura), universal binary |
| 3 | Thư viện USB | Tự viết trên `IOUSBHost`. `libmtp` + `libusb` chỉ là phương án dự phòng nếu thử nghiệm 0a thất bại |
| 4 | Client ADB | Tự viết bằng Swift; dùng adb server của người dùng (cổng 5037) nếu đang chạy, không đóng gói binary `adb` |
| 5 | Gói Free/PRO | Không làm ở bản đầu; chỉ để sẵn một cờ kiểm tra quyền trong code |
| 6 | Thứ tự | ADB trước (giai đoạn 1), MTP sau (giai đoạn 2) |
| 7 | Tên | "DroidDrive" là tên tạm; kiểm tra trùng thương hiệu trước khi phát hành công khai |

## 14. Nguồn

MacDroid (đọc ngày 13/11/2026):

- [Trang chủ](https://www.macdroid.app/), [Mua](https://www.macdroid.app/purchase/), [FAQ](https://www.macdroid.app/faq/), [Thông tin chung](https://www.macdroid.app/faq/macdroid-general-info/)
- [Các kiểu gắn ổ](https://www.macdroid.app/faq/types-of-drive-mouting-used-in-macdroid/), [Cài đặt](https://www.macdroid.app/faq/macdroid-preferences/), [Tùy chọn thiết bị](https://www.macdroid.app/faq/device-options/), [Biểu tượng trạng thái](https://www.macdroid.app/faq/what-do-the-icons-on-my-files-mean/)
- [Kết nối MTP](https://www.macdroid.app/faq/connect-and-mount-android-device-using-mtp/), [Kết nối ADB](https://www.macdroid.app/faq/connect-and-mount-android-device-using-adb/), [Kết nối Wi-Fi](https://www.macdroid.app/faq/how-to-connect-android-device-using-wi-fi/)
- [Thư mục nhiều tệp](https://www.macdroid.app/faq/cannot-access-a-folder-with-a-large-quantity-of-files/), [Thiết bị bị ứng dụng khác dùng](https://www.macdroid.app/faq/cannot-connect-a-phone-while-it-is-being-used-by-another-app/)
- [Lịch sử phiên bản](https://help.electronic.us/support/solutions/articles/44001895298-macdroid-version-history)

Kỹ thuật:

- [FSKit](https://developer.apple.com/documentation/fskit), [FSUnaryFileSystem](https://developer.apple.com/documentation/fskit/fsunaryfilesystem), [FSKitSample](https://github.com/drunlin/FSKitSample)
- [Android Debug Bridge](https://developer.android.com/tools/adb); giao thức: AOSP `packages/modules/adb` (`protocol.txt`, `SYNC.TXT`, `pairing_auth/`, `pairing_connection/`)
- [Commit thêm TLS và mDNS cho adb Wi-Fi](https://gerrit.omnirom.org/plugins/gitiles/android_system_core/+/d85f5c013089d569a6274ae5ab01cfaa613fc872%5E%21), [wadb](https://github.com/lindevhard/wadb), [adb-qr](https://pypi.org/project/adb-qr/)
- `ptpcamerad` chiếm thiết bị: [Apple Community](https://discussions.apple.com/thread/254788819), [MTP trong Rust trên macOS](https://dev.to/hiyoyok/building-an-android-file-transfer-alternative-for-macos-why-it-had-to-be-rust-1m0h), [droidmount](https://awesome.ecosyste.ms/projects/github.com%2Frahuletto%2Fdroidmount)
- Mã lệnh MTP mở rộng của Android: AOSP `frameworks/av/media/mtp/mtp.h`
