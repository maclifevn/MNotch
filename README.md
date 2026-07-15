# MNotch

Dynamic Island cho MacBook — clone Alcove, 100% native Swift/SwiftUI, build không cần Xcode.

## Build & chạy

```sh
Scripts/run.sh        # build + mở app
swift test            # unit test logic lõi
```

Yêu cầu: macOS 15+, Apple Silicon, Swift Command Line Tools.

## Tính năng

- **Notch shell**: panel trong suốt đè lên notch vật lý, mở/đóng bằng hover với spring animation, hoạt động cả trong fullscreen, click ngoài vùng notch xuyên xuống app bên dưới.
- **Now Playing (mọi app)**: album art + visualizer khi đóng; mở ra có artwork glow màu theo bìa, seek bar, prev/play/next, volume. Dữ liệu qua [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter) (BSD-3, vendor source trong `Vendor/`, build bằng clang thuần). Trên macOS 26.5 lệnh `stream` bị chặn nên service poll `get` mỗi 2s + extrapolate elapsed cục bộ.
- **HUD volume/brightness/keyboard backlight** trong notch thay OSD của Apple (cần quyền Accessibility — xem dưới).
- **Battery pop** khi cắm sạc + cảnh báo pin yếu 20%/10%.
- **Bluetooth pop** khi kết nối AirPods/thiết bị, kèm vòng % pin (đọc từ IORegistry).
- **File shelf**: kéo file lên notch → tự mở shelf; kéo ra dùng lại; AirDrop.
- **Calendar**: sự kiện còn lại trong ngày.
- **Settings** (icon bánh răng trong panel): bật/tắt từng tính năng, fake notch trên màn ngoài, launch at login.
- **Agent approvals + quota**: Claude Code và Codex có thể gửi permission request vào notch để xem nội dung rồi Allow/Deny. Khi không có request, tab Agent hiển thị quota chính thức còn lại theo cửa sổ 5 giờ/7 ngày, thời điểm reset và trạng thái live/cache. Cài hook trong Settings → Agents; với Codex, mở `/hooks` một lần để review/trust command theo cơ chế bảo mật của Codex.

## Quyền

| Quyền | Cần cho | Ghi chú |
|---|---|---|
| Accessibility | Nuốt phím volume/brightness (ẩn OSD Apple) | Không có → HUD vẫn hiện song song OSD |
| Calendar | Tab lịch | Hỏi khi mở tab lần đầu |
| Bluetooth | Pop thiết bị | Hỏi lần đầu |

**Quan trọng:** trước khi cấp Accessibility, tạo cert ký code ổn định theo [Scripts/sign-cert-setup.md](Scripts/sign-cert-setup.md) — nếu không, mỗi lần rebuild quyền sẽ bị reset (ad-hoc signing đổi identity liên tục).

## Kiến trúc

- `Window/` — NSPanel non-activating cố định kích thước, hitTest pass-through; mọi animation nằm trong SwiftUI.
- `Shape/NotchShape.swift` — outline notch với radii animatable (góc trên lõm, dưới bo).
- `State/NotchViewModel.swift` — state machine `closed / hud / pop / expanded` + hover intent (mở 120ms, đóng 350ms); toàn bộ spring định nghĩa ở `State/Anim.swift`.
- `Services/` — media (perl adapter), CoreAudio, CGEventTap, DisplayServices/CoreBrightness (private, degrade an toàn), IOKit power, IOBluetooth.

Các tác vụ file/transcript chạy ngoài main actor; service dài hạn có lifecycle
`start/stop` rõ ràng. CI kiểm tra debug build, unit test, release build và cú
pháp các relay script trên mỗi push/PR.

Lock-screen presence (như Alcove) không khả thi từ app thường — ngoài scope.
