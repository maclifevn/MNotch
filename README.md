# MNotch

Dynamic Island cho Mac

## Build & chạy

```sh
Scripts/run.sh        # build + mở app
swift test            # unit test logic lõi
```

Yêu cầu: macOS 15+, Apple Silicon, Swift Command Line Tools.

### Bản phát hành đã notarize

Lưu thông tin notarization vào Keychain một lần (password phải là app-specific
password của Apple ID):

```sh
xcrun notarytool store-credentials "MNotch-notary" \
  --apple-id "YOUR_APPLE_ID" \
  --team-id "CF5PGH3KGK"
```

Sau đó build, ký Developer ID, notarize, staple và đóng gói bằng:

```sh
Scripts/notarize.sh
```

File để chia sẻ được tạo tại `build/distribution/MNotch.zip`.

Để tạo thêm disk image kéo-thả chuẩn macOS (MNotch → Applications), chạy:

```sh
Scripts/create-dmg.sh
```

DMG đã ký và notarize được tạo tại `build/distribution/MNotch.dmg`.

## Tính năng

- **Notch shell**: panel trong suốt đè lên notch vật lý, mở/đóng bằng hover với spring animation, hoạt động cả trong fullscreen, click ngoài vùng notch xuyên xuống app bên dưới.
- **Now Playing (mọi app)**: album art + visualizer khi đóng; mở ra có artwork glow màu theo bìa, seek bar, prev/play/next, volume. Dữ liệu qua [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter) (BSD-3, vendor source trong `Vendor/`, build bằng clang thuần). Service poll thích ứng 2 giây khi có media và 10 giây khi rảnh; elapsed được nội suy cục bộ.
- **HUD volume/brightness/keyboard backlight** trong notch thay OSD của Apple (cần quyền Accessibility — xem dưới).
- **Battery pop** khi cắm sạc + cảnh báo pin yếu 20%/10%.
- **Bluetooth pop** khi kết nối AirPods/thiết bị, kèm vòng % pin (đọc từ IORegistry).
- **File Tray**: kéo file lên notch → tự mở tray; chọn nhiều file, Quick Look, Open, Reveal in Finder, kéo ra hoặc AirDrop. Thumbnail có cache và danh sách lazy để vẫn mượt khi nhiều file.
- **Calendar**: sự kiện còn lại trong ngày.
- **Settings** (icon bánh răng trong panel): bật/tắt từng tính năng, fake notch trên màn ngoài, launch at login.
- **Agent approvals + quota**: Claude Code và Codex có thể gửi permission request vào notch để xem nội dung rồi Allow/Deny. Khi không có request, tab Agent hiển thị quota còn lại theo cửa sổ 5 giờ/7 ngày, thời điểm reset và trạng thái live/cache. Codex lấy từ App Server chính thức; Claude lấy từ `/usage` của CLI cục bộ, không đọc transcript hay Keychain. Cài hook trong Settings → Agents; với Codex, mở `/hooks` một lần để review/trust command theo cơ chế bảo mật của Codex.

## Quyền

| Quyền | Cần cho | Ghi chú |
|---|---|---|
| Accessibility | Nuốt phím volume/brightness (ẩn OSD Apple) | Không có → HUD vẫn hiện song song OSD |
| Calendar | Tab lịch | Hỏi khi mở tab lần đầu |
| Bluetooth | Pop thiết bị | Hỏi lần đầu |
| Full Disk Access | Đọc trạng thái Focus hiện tại | Không có → Focus tự tắt an toàn |
| Apple Events | Favorite trong Music / quay lại Terminal agent | Chỉ hỏi khi dùng action tương ứng |

Nếu Accessibility chưa được cấp trong khi HUD phím đang bật, MNotch gắn badge
cảnh báo lên icon menu bar, hiện trạng thái có thể bấm trong menu, nhắc một lần
trên notch khi khởi động và luôn có nút cấp quyền tại Settings → General.

**Quan trọng:** trước khi cấp Accessibility, tạo cert ký code ổn định theo [Scripts/sign-cert-setup.md](Scripts/sign-cert-setup.md) — nếu không, mỗi lần rebuild quyền sẽ bị reset (ad-hoc signing đổi identity liên tục).

## Kiến trúc

- `Window/` — NSPanel non-activating cố định kích thước, hitTest pass-through; mọi animation nằm trong SwiftUI.
- `Shape/NotchShape.swift` — outline notch với radii animatable (góc trên lõm, dưới bo).
- `State/NotchViewModel.swift` — state machine `closed / hud / pop / expanded` + hover intent (mở 120ms, đóng 350ms); panel tự đo chiều cao từng tab và toàn bộ motion policy nằm ở `State/Anim.swift`.
- `Services/` — media (perl adapter), CoreAudio, CGEventTap, DisplayServices/CoreBrightness (private, degrade an toàn), IOKit power, IOBluetooth.
- `App/FeatureCoordinator.swift` — một nơi duy nhất tính demand và start/stop/reconfigure service theo Settings; polling nặng dừng khi màn hình ngủ.

Các tác vụ file/transcript chạy ngoài main actor; service dài hạn có lifecycle
`start/stop` rõ ràng. CI kiểm tra debug build, unit test, release build và cú
pháp các relay script trên mỗi push/PR.

Lock-screen overlay dùng SkyLight private API và luôn fail-closed: nếu phiên bản macOS hiện tại không còn tương thích, MNotch tắt riêng overlay thay vì crash hay để panel lọt ra desktop.
