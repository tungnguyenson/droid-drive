# DroidDrive

DroidDrive là một ứng dụng macOS gắn điện thoại Android vào Finder thành một ổ đĩa, để duyệt, mở, sửa và chép tệp như với ổ USB. Nó dùng File Provider, cơ chế mà iCloud Drive và Google Drive dùng, nên không cần macFUSE hay kernel extension. Đặc tả nằm ở [`docs/spec.md`](docs/spec.md), kế hoạch và tiến độ ở [`docs/plan.md`](docs/plan.md), kết quả các bài thử ở [`docs/spikes.md`](docs/spikes.md).

Trạng thái (tối 14/11/2026): đã có code cho bốn giai đoạn đầu của kế hoạch. Đã thử với Android Emulator và với một Pixel thật qua Wi-Fi (adb server). ADB qua USB không cần adb server, và MTP, mới chạy với thiết bị giả; ghép đôi Wi-Fi của chính DroidDrive đã thử với emulator. Giao diện chỉ có tiếng Anh. Chi tiết ở mục 5 của kế hoạch.

## Build và chạy thử

Cần Xcode 26 trở lên và [XcodeGen](https://github.com/yonaskolb/XcodeGen). Project Xcode được sinh ra từ `project.yml`, không commit vào repo. Team ký nằm trong `Config/Signing.xcconfig`; muốn dùng team khác thì tạo `Config/Signing.local.xcconfig` (đã bỏ qua trong git).

```sh
xcodegen generate
xcodebuild -project DroidDrive.xcodeproj -scheme DroidDrive -derivedDataPath build/app \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Apple Development" PROVISIONING_PROFILE_SPECIFIER= build
open build/app/Build/Products/Debug/DroidDrive.app
```

App nằm trên thanh menu, có các cửa sổ Devices, Connect via Wi-Fi, Transfer Log và Settings. Nó tìm điện thoại qua adb server (nếu đang chạy), qua USB (ADB hoặc MTP), và qua Wi-Fi với máy đã ghép đôi trong cửa sổ Connect via Wi-Fi; extension File Provider gọi app qua XPC, nên app phải chạy thì ổ mới đọc ghi được.

Lần đầu gắn, macOS để ổ ở trạng thái tắt. Bật DroidDrive trong Cài đặt hệ thống → Chung → Mục đăng nhập & Tiện ích mở rộng → File Provider; menu của DroidDrive có nút mở đúng trang này.

## Dùng hằng ngày

Bản dùng thật nằm ở `/Applications/DroidDrive.app` và tự chạy khi đăng nhập (Settings → Open at login); biểu tượng điện thoại trên thanh menu là nó. Mỗi lần cần lấy tệp:

1. Trên điện thoại, bật Tùy chọn nhà phát triển → **Gỡ lỗi không dây** (Android tự tắt nó khi khởi động lại hoặc đổi mạng Wi-Fi). Điện thoại và Mac cùng một mạng Wi-Fi.
2. Vài giây sau, menu DroidDrive hiện điện thoại "· Mounted" và ổ hiện trong thanh bên Finder (mục Locations). Không phải ghép đôi lại.
3. Dùng ổ như một thư mục thường. Xong thì cứ tắt Gỡ lỗi không dây; tệp đã mở vẫn còn trên Mac, thay đổi chưa gửi sẽ gửi ở lần nối sau.

Cắm cáp USB (chế độ "Truyền tệp", có Gỡ lỗi USB) cũng được, chưa thử với máy thật.

Cập nhật bản dùng thật sau khi sửa code: build cấu hình Release như mục trên (thay `build` bằng `-configuration Release build`), thoát DroidDrive, chép `build/app/Build/Products/Release/DroidDrive.app` đè lên `/Applications/DroidDrive.app`, rồi mở lại.

## Nối điện thoại qua Wi-Fi

Có hai cách. Cách của DroidDrive: menu → Connect via Wi-Fi…, rồi quét mã QR hoặc nhập mã 6 số; DroidDrive tự ghép đôi, tự kết nối và tự nối lại về sau. Cách qua adb: điện thoại nào adb server thấy thì DroidDrive cũng thấy. Với Android 11 trở lên: bật Gỡ lỗi không dây trong Tùy chọn nhà phát triển, chọn "Ghép nối thiết bị bằng mã ghép nối", rồi trên Mac chạy hai lệnh dưới đây (`adb mdns services` cho biết địa chỉ và cổng điện thoại đang quảng bá). Cổng của `pair` và của `connect` khác nhau, đều đọc trên màn hình điện thoại. Ổ đặt tên theo serial của điện thoại, nên đổi cổng hay chuyển giữa USB và Wi-Fi vẫn là cùng một ổ.

```sh
adb pair 192.168.1.23:37123      # nhập mã 6 số
adb connect 192.168.1.23:41234
```

## Test

Unit test không cần thiết bị. Test tích hợp chỉ chạy khi có biến môi trường trỏ tới một thiết bị: emulator hoặc điện thoại thật đã cho phép ADB.

```sh
cd Packages
swift test                                              # unit test
DROIDDRIVE_ADB_SERIAL=emulator-5554 swift test          # thêm test tích hợp qua adb server
DROIDDRIVE_ADB_SERIAL=<serial> DROIDDRIVE_TEST_ROOT=/storage/emulated/0/DroidDriveTest \
  swift test --filter IntegrationTests                   # trên điện thoại thật, chỉ ghi trong thư mục đó
DROIDDRIVE_ADB_DIRECT=127.0.0.1:5555 swift test \
  --filter IntegrationTests                              # nối thẳng adbd (tắt adb server trước)
```

Ba công cụ dòng lệnh trong `Packages/`, không đóng gói vào app: `droiddrive-cli` gọi thẳng client ADB (thử nhanh, đo tốc độ so với `adb`), `droiddrive-usb` thử USB và MTP (bài S0-a), `droiddrive-wifi` thử ghép đôi và kết nối Wi-Fi (`discover`, `pair`, `qr`, `connect`). Ví dụ:

```sh
swift run -c release droiddrive-cli storages
swift run -c release droiddrive-cli push ./big.bin /storage/emulated/0/Download/big.bin
```
