# MNotch — audit ổn định, dữ liệu và phân phối

## Production review lần 2 — 20/10/2026

**Kết luận hiện tại: ứng viên QA đã notarize; chưa ký duyệt phát hành production.**
Mã cuối đã qua các kiểm tra tự động bên dưới. Còn thiếu CI macOS 15/26 cho đúng
commit chứa các sửa đổi, ma trận thiết bị/quyền/update-install thực tế và workload
soak 8 giờ. Không dùng notarization hoặc idle smoke để thay thế các mục này.
Các phần bên dưới ghi riêng kết quả đợt trước, không phải trạng thái của ứng viên này.

Ứng viên riêng: **1.4.1-audit2 (93)**, Apple Silicon/macOS 15+, build trên macOS
27.0.1 (26A434). Working tree chưa commit/tag; HEAD gốc là
`87d845c33d4a26d609ebc7058ff04c388509e5e7`. CI gần nhất của HEAD đó xanh,
nhưng không bao phủ thay đổi chưa commit. Không có public release/feed mới.

### Phát hiện bổ sung và sửa

| ID / mức độ | Đường lỗi | Sửa và bằng chứng |
|---|---|---|
| P01 / P2 tài nguyên | Thumbnail cũ sống độc lập với task của view; đóng tab không hủy chờ, provider không trả lời có thể giữ entry. | Pool chia sẻ giữa panel: tối đa 4 yêu cầu đang chạy, 100 entry, timeout 15s cho yêu cầu đang chạy, hủy waiter theo vòng đời view; waiter cuối hủy native request. Kết quả trễ bị loại bằng UUID generation. 7 test gồm provider Quick Look thật với PNG local, 100 view hủy, shared waiter, timeout, invalidate/recycled URL và callback đồng bộ. |
| P02 / P2 UI đúng dữ liệu | Cache chỉ invalidate từ ShelfView, không bao phủ file rời khay lúc tab đã đóng. | Đưa invalidate về owner của danh sách ShelfStore; callback view không còn là nơi duy nhất giữ tính đúng của cache. |
| P03 / P1 nghẽn main | AgentServer đọc token bằng FileHandle trực tiếp; token dạng FIFO có thể làm open/read chờ vô hạn. BoundedFileReader cũ kiểm tra path trước rồi mở, có khoảng TOCTOU. | Mở descriptor với O_NONBLOCK/O_CLOEXEC, fstat đúng descriptor, chỉ đọc regular file và kiểm tra size. Giữ hỗ trợ symlink dotfile hợp lệ. Agent token đi qua reader này. Test FIFO không writer, /dev/zero, symlink regular và startup server với token FIFO đều qua. |
| P04 / P1 dữ liệu | fileExists theo symlink nên coi link đứt là tên chưa tồn tại; drop trùng tên có thể đưa link cũ vào cleanup của copy thất bại. Clear cũng bỏ qua link đứt. | Dùng lstat để chọn tên, lỗi lookup thoát có kiểm soát; Clear xử lý link như item. Test giữ nguyên link cũ khi drop trùng tên và Clear link đứt; fixture dùng thao tác xóa riêng trong thư mục test, không đưa file vào Trash thật. |
| P05 / phòng vệ copy | Input có thể là chính Shelf hoặc thư mục chứa nó, kể cả alias symlink. | Chặn bằng canonical path trước khi copy bất cứ item nào của batch. Test self/ancestor/symlink ancestor và giữ nguyên source/batch rỗng. Không chạy copy đệ quy không giới hạn để tái hiện hết dung lượng. |
| P06 / P2 UX | Animation opacity đặt trên cả subtree có thể áp animation đóng lên geometry của HUD khi auto-hide đổi trạng thái. | Giới hạn animation vào opacity để giữ transaction/speed riêng của HUD và panel. Kiểm thử state/native và build release qua. |
| P07 / P1 release gate | prepare có thể đi tới notarization mà không tự chạy lại regression trên source/tag; manifest không có record kiểm thử. | Prepare bắt buộc debug, release, ASan, TSan, Python checks; kiểm lại source/tag trước upload. Publish từ chối manifest thiếu record. Test lỗi regression dừng trước notarization và manifest cũ không thể publish. Manifest là record quy trình, không phải chứng thực độc lập về test hardware. |
| P08 / P2 độ tin cậy QA | Smoke ngắn vẫn được báo thành công dù đã có đủ mẫu phát hiện tăng tài nguyên. | Phân loại resource_review_required trước nhánh smoke_completed; test growth/host sleep/failure và thiếu warm-up. Soak copy có tùy chọn Developer ID để giữ hardened runtime/entitlements và ghi SHA-256 binary, không chỉ đo bản ad-hoc. |

### Kết quả thực sự đã chạy

- **127/127** debug, **127/127** release, **127/127** Address Sanitizer và
  **127/127** Thread Sanitizer trên mã cuối. Không có ASan/TSan report. Các log
  CoreData/Contacts XPC 4097 vẫn xuất hiện trong test host và được giữ lại.
- **32/32** Python checks: relay, binary metadata/dSYM, signed-feed/tamper bằng
  khóa fixture, release gates và soak classification. Không dùng Sparkle private
  key production trong fixture; không xuất/đổi private key.
- Bundle verifier: **7 Mach-O**, minOS hợp lệ, executable UUID khớp output hiện
  tại, dSYM đúng UUID và có DWARF. codesign deep/strict qua. Một Clang extension
  warning cũ nằm ở MediaRemoteAdapterTestClient, không nằm trong app được đóng gói.
- Developer ID + timestamp + hardened runtime đã xác nhận trên app và bản sao
  native. Entitlements của app chỉ gồm Apple Events và Calendars; không thêm
  get-task-allow hoặc ngoại lệ tắt library validation/JIT để làm test qua.
- Apple Notary trả **Accepted**, submission
  `4f8b82eb-1032-4a4a-84bb-9b775da5b252`; log `issues: null`, SHA-256 archive
  khớp. Staple, validate ticket và Gatekeeper sau staple đều qua. ZIP bàn giao
  được tạo lại sau staple. Lượt Gatekeeper trước staple bị reject được giữ làm
  bằng chứng chuyển trạng thái, không phải kết quả cuối.
- Native trên ứng viên cuối: Settings mở được, **20 vòng đóng/mở** bằng ⌘W/⌘,
  thành công; xác nhận trạng thái không phát hiện notch thật, simulated notch
  tự bật, auto-hide bật được; nhãn âm thanh và Agent off/disabled Refresh Now
  đúng sau stress. Bài kiểm tra NSPanel thật trong suite kiểm tra reveal region,
  click pass-through, suppression và recovery. Chưa đo FPS/latency khi drag file
  thật, không coi kiểm tra Settings là bao phủ toàn bộ UI notch.

### Bộ nhớ và thời gian chạy

Lượt native cuối và raw CSV/heartbeat nằm ở
`build/audit/production-review-2026-10-20/native-final`. Chỉ dùng result.json
của đúng bản sao QA để nghiệm thu lượt này; lượt native-hardened trước đó là
baseline đã bị thay thế sau khi bổ sung sửa symlink. Binary của bản sao đổi SHA
khi ký lại bằng bundle ID riêng; `native-code-identity.json` xác nhận cùng build
UUID, mọi section code/data và load commands (chỉ bỏ phần chữ ký/linkedit size)
khớp ứng viên notarized. Manifest lưu riêng hai SHA, không giả định chữ ký giống nhau.

**Kết quả cuối: 750.074s, 145 mẫu, smoke_completed**; sau warm-up 600s có
**28 mẫu**, RSS **100.92–118.86 MiB**, CPU trung vị **0.9%**, FD **3–3**,
child count **0–1** (helper media tạm thời). Median RSS quý cuối thấp hơn quý đầu
**13,584 KiB**, FD/child median không tăng; không phát hiện tín hiệu tăng tài
nguyên theo ngưỡng harness. RSS dao động/giảm nên không gọi đây là plateau
chính xác hoặc chứng minh không leak. vmmap ở đầu lượt: footprint **56.9 MiB**,
peak **58.6 MiB**. Đây là Settings stress rồi idle trên máy hiện tại, chưa phải
8 giờ workload và không phải chứng nhận frame pacing hay thiết bị khác.

Đối chứng tối giản không chứa logic/service MNotch, chỉ có AppKit + SwiftUI +
window/menu, cũng báo ba root cycle NSXPCConnection protocol
LNDaemonApplicationInterface: **417 allocation / 20,016 byte**. Bản hardened
cuối cũng báo đúng số này. Đây là bằng chứng nền framework/tool trên host,
không đủ để quy chúng thành leak riêng của MNotch. leaks vẫn báo giới hạn đọc
memory của process không debuggable; không suy luận rằng mọi leak đã bị loại
hoặc hệ điều hành chắc chắn có bug. Cả source control app và raw leak reports
đều được giữ trong evidence. Các lần vmmap/leaks có thể tạm dừng process.

### Những tiêu chí chưa đủ bằng chứng để duyệt public release

1. Chốt commit/version/build và CI xanh cho chính source cuối trên macOS 15/26;
   không thay kết quả CI của HEAD cũ cho working tree đang sửa.
2. Hardware/permission matrix: display hot-plug/clamshell, sleep/wake/lock,
   AirPods/HDMI, TCC revoke, file lớn/volume mất/đầy ổ, agent/account thật và
   cập nhật từ bản notarized cũ. Private brightness/backlight/lock integration
   vẫn bị gate, không tự mở allowlist để hợp thức hóa kiểm thử.
3. Workload soak 8 giờ và đo animation/drag bằng profiler. Các lượt ngắn hiện
   có chỉ hỗ trợ kết luận smoke; chuẩn bị notarized ZIP không hoàn thành mục này.

### Evidence / chạy lại

- Ứng viên notarized: `build/MNotch.app` và
  `build/audit/production-review-2026-10-20/MNotch-notarized-candidate.zip`.
- Symbols: `build/symbols/1.4.1-audit2-93`.
- Source snapshot chứa cả hai file mới chưa tracked: `source-snapshot.zip`;
  patch tracked: `changes.patch`; symbols archive: `MNotch-symbols.zip` trong
  thư mục evidence bên dưới.
- Logs, Notary receipt/log, Gatekeeper/stapler, nguồn/hash và native runs:
  `build/audit/production-review-2026-10-20`.
- `make release` hiện bắt buộc kiểm thử lại trước notarization; vẫn yêu cầu
  commit/tag/notes sạch. Không chạy publish trong đợt audit này.

Tiêu chí phân phối được đối chiếu với [Apple notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
và [chuẩn bị app để phân phối](https://developer.apple.com/documentation/xcode/preparing-your-app-for-distribution).
Sparkle vẫn pin **2.10.0**, khớp bản latest tại thời điểm kiểm tra từ
[release upstream](https://github.com/sparkle-project/Sparkle/releases/tag/2.10.0);
đã xem [security advisories](https://github.com/sparkle-project/Sparkle/security/advisories).
Không đổi dependency chỉ để tạo thay đổi trong audit.

---

## Cập nhật QA native — 20/10/2026

Host thực tế: macOS **27.0.1 (26A434)**, Apple Silicon. Phạm vi lần này là
mã nguồn hiện tại, tính năng tự ẩn notch vừa thêm, vòng đời cửa sổ/service,
đường render, bộ nhớ và UI/UX native. Các kết quả ngày 02/10 bên dưới là lịch sử,
không phải kết quả chạy lại trong phiên này.

### Các lỗi đã sửa

| ID / mức độ | Bằng chứng và ảnh hưởng | Thay đổi |
|---|---|---|
| N01 / P2 hiệu năng | Đặt opacity=0 không dừng TimelineView của waveform; alpha=0 khi occlusion cũng không báo trạng thái render cho SwiftUI. | Truyền trạng thái tạm dừng render xuống waveform; giữ nguyên cây view và vùng tương tác để notch tự ẩn có thể hiện lại. |
| N02 / P2 bộ nhớ | Thumbnail yêu cầu 104pt ở scale 2, nhưng cache chỉ tính 104×104×4 byte; invalidate chỉ hủy Swift Task, không hủy yêu cầu Quick Look đang chạy. | Tính chi phí ảnh 208×208×4, giữ nguyên giới hạn cache; gọi cancel của QLThumbnailGenerator khi invalidate, vẫn kiểm tra generation trước khi lưu kết quả. |
| N03 / P2 vòng đời | Khi IOPS không tạo được nguồn thông báo, observer Low Power vẫn tồn tại nhưng start chỉ kiểm tra nguồn IOPS; start lặp có thể mất token observer cũ. Callback Task đã xếp hàng cũng có thể chạy sau stop/restart. | Guard cả hai registration; token generation loại callback cũ. Test mô phỏng IOPS thất bại, gọi start 100 lần và stop/restart trước delivery. |
| N04 / P2 logic/UX | Agent Monitor tắt nhưng quota vẫn hiển thị Connecting/Loading; Refresh Now còn có thể gọi client và khởi động helper ngoài vòng đời service. | Hiển thị trạng thái tắt, disable Refresh Now và guard refresh tại QuotaService. Coalesce việc dò Claude CLI khi app nhận activation liên tiếp. |
| N05 / P2 accessibility | QA native thấy toggle âm thanh có tên rỗng; nút play chỉ mang tên biểu tượng. Một số nút media/Pomodoro/terminal chưa có nhãn hành động rõ. | Bổ sung nhãn VoiceOver và tooltip có bản dịch; giữ tiêu đề của toggle ngay khi ẩn nhãn nhìn thấy. Đã xác nhận lại tên toggle và nút Preview sound trên release. |
| N06 / P2 UX | Menu chính chỉ có Close/Quit; phím ⌘, chưa có target toàn app để mở lại Settings khi cửa sổ đã đóng. | Thêm Settings vào main menu và target rõ ràng; đã chạy 10 vòng đóng/mở bằng ⌘W/⌘, trên debug và 10 vòng trên release. |
| N07 / phòng vệ | Visualizer giả định gradient không rỗng, phép modulo có thể trap nếu có caller truyền mảng rỗng. Các caller hiện tại đều truyền mảng hợp lệ. | Fallback về màu đơn khi gradient rỗng. Không coi đây là crash đã tái hiện từ thao tác người dùng. |

### Kiểm tra đã thực sự chạy trong phiên này

- Debug, release, Address Sanitizer và Thread Sanitizer: **115/115 mỗi lượt**.
  Không có báo cáo ASan/TSan. Test cuối bao gồm cửa sổ NSPanel/NSHostingView thật
  với geometry simulated: hidden → reveal → outside pass-through → suppression
  → recovery, cùng test persistence và physical-notch exemption.
- Kiểm tra Python cho relay/build/bundle/soak/update: **25/25**.
- Đóng gói release: **7 Mach-O**, deployment target hợp lệ, dSYM khớp và có debug
  info; script verify bundle và codesign hoàn tất. Bản local ad-hoc 1.4 (93),
  chưa xuất bản hay cài đè bản người dùng.
- Localization plist lint và diff whitespace: qua. Có một key Focus trùng với
  giá trị giống nhau trong tài nguyên tiếng Việt từ trước; không gây lỗi lint.
- QA native trên bản sao có bundle ID và support directory riêng: đã mở đủ
  General, Battery, Connectivity, Focus, Display/Sound, Now Playing, Calendar,
  Pomodoro, File Tray, Lock Screen, Agents, About. Đã xem ảnh bố cục General,
  Now Playing, File Tray và About; xác nhận toggle tự ẩn hoạt động trong Settings,
  trạng thái Agent tắt và tên điều khiển âm thanh sau sửa. Bản release tiếng Việt
  riêng cũng xác nhận bản dịch, bố cục tự ẩn, nhãn VoiceOver và thoát bằng ⌘Q.
  Không cài hook, cấp
  thêm quyền hoặc chạy update thật.
- Debug smoke 180s/34 mẫu và 300s/58 mẫu hoàn tất. RSS tăng lúc khởi động và
  mở nhiều pane; không suy luận leak chỉ từ chênh lệch đầu/cuối. Profile debug
  3s ghi 1756/1792 mẫu main thread chờ Mach port, không thấy chặn I/O trên main
  trong khoảng mẫu đó. Release được lấy thêm mẫu 15s khi mở/đóng, cuộn và
  chuyển General/Now Playing/File Tray/About: 9786/10666 mẫu main thread chờ
  Mach port; footprint 65.7 MiB, peak 66.3 MiB. SubprocessRunner xuất hiện trên
  worker riêng. Không dùng các con số này như đo frame time khi animation/drag.

### Bộ nhớ native và giới hạn kết luận

Lượt release **750.078s (12,5 phút), 148 mẫu** đã hoàn tất, trạng thái
`smoke_completed`, không tự thoát hoặc mất heartbeat. Sau warm-up 600s có
**30 mẫu**: RSS **139.1875–139.2344 MiB**, CPU trung vị **0.7%**, FD **3–3**,
child count **0** tại mọi thời điểm lấy mẫu. Median RSS quý đầu/cuối sau warm-up
chênh **0 KiB**; FD/child cũng không tăng. Main-thread heartbeat trong khoảng
đó **4.999893–5.000036s**. Raw CSV/heartbeat/profile/result và summary nằm trong
`build/audit/native-2026-10-20-release`. Đây là smoke với thao tác Settings rồi
idle, không phải soak 8 giờ hoặc chứng nhận mọi workload/hardware.

`vmmap` ở khoảng phút đầu sau mở Settings báo footprint **63.1 MiB**. RSS khác
footprint vì còn chứa trang thư viện dùng chung. Công cụ `leaks` ban đầu báo
**411 allocation / 19,760 byte** trong ba root cycle NSXPCConnection,
protocol LNDaemonApplicationInterface, với block của Foundation. Công cụ cũng
báo process không debuggable và giới hạn đọc bộ nhớ. Chưa có allocation stack
để quy nguồn tạo cho MNotch; không tuyên bố sạch leak hoặc kết luận chắc chắn
là bug hệ điều hành. Raw output được giữ để đối chiếu lượt đo sau tương tác.
Sau 10 vòng đóng/mở Settings trên release, phép đo lại vẫn đúng 411 allocation /
19,760 byte; chưa thấy tăng theo số vòng. Các lần vmmap/leaks có thể tạm dừng
tiến trình, ảnh hưởng heartbeat đúng lúc đo.

Test host có log CoreData/Contacts XPC 4097 từ framework hệ thống. Các suite vẫn
qua, không có sanitizer report; log được giữ nguyên trong evidence, không được
đổi thành tuyên bố rằng runtime không có cảnh báo.

Còn cần ma trận phần cứng/OS: hot-plug và clamshell thật, sleep/wake/lock thật,
AirPods/HDMI và driver stall, revoke quyền trong callback, file lớn/volume ngắt/
đầy ổ, update Developer ID thật, và workload soak 8 giờ. UI của private
brightness/backlight/lock integration vẫn bị gate theo policy hiện có; không
mở gate để thử trên máy người dùng. Độ mượt khi drag/animation cần Instruments
trên workload tương tác; idle sample không thay thế kiểm tra đó.

### Evidence và bản có thể chạy

- App release: `build/MNotch.app`.
- Native runs: `build/audit/native-2026-10-20-{baseline,ui,release}`.
- Logs kiểm thử và đóng gói: `build/audit/checks-2026-10-20`.
- Source diff của phiên: `build/audit/changes-2026-10-20.patch`.

---

## Lịch sử audit — 02/10/2026

Ngày kiểm tra: 02/10/2026. Phạm vi giữ nguyên Apple Silicon, macOS 15+, local-first.
Bản ứng viên: **1.4.1-audit, build 90**, ad-hoc, chưa phát hành.

## Kết luận và giới hạn

Đã rà soát mã của tất cả nhóm tính năng, sửa các lỗi xác định được trong mã và
bổ sung kiểm thử cho những đường lỗi chính. **Chưa có crash log/hang sample của
người báo lỗi; chưa xác định được nguyên nhân các báo cáo ngoài thực tế.**

Các phát hiện dưới đây phân biệt lỗi có đường kích hoạt xác định với rủi ro
chưa được tái hiện trên thiết bị. Test dùng payload, subprocess và nguồn dữ liệu
giả có kiểm soát; chúng không thay thế ma trận phần cứng, quyền và vòng đời.

Tích hợp riêng **DisplayServices, CoreBrightness keyboard backlight và SkyLight**
được chặn trước khi gọi API vì chưa có môi trường nào hoàn tất ma trận tương
thích. Settings hiển thị lý do; macOS tiếp tục xử lý các phím tương ứng. Âm lượng
và các tính năng còn lại tiếp tục hoạt động. MediaRemote vẫn chạy trong helper
Perl riêng, có deadline và giới hạn đầu ra; helper này chưa được chứng nhận trên
toàn bộ các phiên bản OS.

## Phát hiện và cách xử lý

P1: ưu tiên trước khi phát hành vì có thể gây crash, treo hoặc mất dữ liệu.
P2: tài nguyên, độ tin cậy hoặc phân phối; không đồng nghĩa đã có khai thác thực tế.

| ID / mức độ | Vị trí | Điều kiện, bằng chứng và ảnh hưởng | Sửa / kiểm thử |
|---|---|---|---|
| A01 / P1 | `MediaRemoteService`, `QuotaModels`, media time/slider | Chuỗi `nan`, `inf`, số lớn hơn miền Int; `Double(Int.max)` làm tròn lên. Chuyển kiểu không kiểm tra có thể trap; time/range sai có thể đi tới UI. | `SafeNumeric`, miền thời gian, seek microseconds và slider hữu hạn. Test payload media/quota, Int biên, seek và HUD sai số. |
| A02 / P1 | `SettingsStore` | Preference số hỏng/ngoài miền được dùng cho Int, timer, Pomodoro hoặc geometry. | Kiểm tra 20 preference số khi đọc và ghi; trả về mặc định hiện có. Test suite UserDefaults riêng, mọi miền và gán runtime không hợp lệ. |
| A03 / P1 | `AgentMonitorService`, media AppleScript actions | `waitUntilExit()` và AppleScript đồng bộ có thể chặn main actor nếu terminal/media app không trả lời. | Chạy qua helper có deadline, tách công việc blocking sang GCD. Rà lại các đường gọi; profiler idle không thấy main thread bị chặn trong khoảng mẫu. TCC/terminal thật còn cần kiểm thử thủ công. |
| A04 / P1 | Media/Claude subprocess | TERM không bảo đảm thoát; chờ EOF sau khi leader đã thoát có thể bị descendant giữ pipe. Đọc tuần tự stderr/stdout cũng có thể deadlock khi pipe đầy. | Runner POSIX đọc công bằng hai pipe, deadline media 8s / Claude 30s, TERM→KILL nhóm tiến trình, đóng reader và reap có giới hạn. Test child bỏ qua TERM, descendant giữ pipe, cancel trước/sau launch, hai đầu ra 120 KB và giới hạn chung. Deadline có thêm thời gian thu hồi tối đa khoảng 1.25s. |
| A05 / P1 | `CodexQuotaClient.send` | Child đóng stdin; `write(2)` có thể phát SIGPIPE. Child không đọc stdin có thể làm đầy pipe. | Kiểm tra thiết lập nonblocking và `F_SETNOSIGPIPE`; xử lý EPIPE/EAGAIN bằng recycle. Fixture thật đóng stdin xác nhận app/test không bị tín hiệu kết thúc. |
| A06 / P1 | Codex quota reader | Dòng không kết thúc, stdout quá lớn hoặc callback nhanh tạo buffer/backlog không giới hạn. | Buffer 1 MiB, chunk 16 KiB, stream tối đa 32 chunk, một reader task, một RPC đang chờ, timeout 10s và backoff. Test 2 MB không newline, stream overflow và 100 start/stop với callback đến muộn. |
| A07 / P2 | Codex teardown | Leader thoát khi nhận TERM, descendant bỏ qua TERM vẫn giữ pipe. Kiểm tra thực tế Foundation Process trên host xác nhận child có process group riêng. | Lưu group sở hữu lúc launch; KILL group sau grace dù leader đã thoát. Fixture fork child giữ pipe kiểm tra PID descendant được thu hồi. Không tuyên bố thu hồi daemon tự chuyển sang process group khác. |
| A08 / P1 | `CalendarService` | Hủy Task không hủy truy vấn EventKit/permission callback; restart có thể tích lũy truy vấn và callback cũ có thể dựng lại observer/timer. | EventKit trên queue riêng; giữ tối đa một tác vụ permission và một query thực sự đang chạy, chỉ phục vụ yêu cầu mới nhất; token chặn kết quả cũ, xóa dữ liệu khi stop/revoke. Hai test riêng 100 restart với permission/query bị giữ. |
| A09 / P2 | Audio/Bluetooth/Focus/occlusion và timers | Callback dồn dập hoặc tới sau stop/restart; timer closure giữ owner; việc hủy đọc blocking không tự thu hồi công việc. | Audio coalesce notification và mailbox trước main actor; Bluetooth kiểm tra registration identity/generation, unregister disconnect token; Focus/occlusion giữ single-flight; các timer callback weak. Test 100.000 mailbox updates, 100 vòng Pomodoro và giải phóng owner. Bluetooth/HAL thật chưa hoàn tất ma trận hot-plug. |
| A10 / P2 | `AgentServer` | Kết nối chưa xác thực chưa được quản lý đủ; client im lặng giữ socket; decode payload trước khi kiểm tra kích thước. | Theo dõi mọi connection, tối đa 32, deadline đọc 5s, payload tối đa 1.000.000 byte trước decode, generation và stop đóng toàn bộ. Test listener 100 restart, EOF khi stop, token sai, payload quá lớn và event hợp lệ; token file 0600. |
| A11 / P2 | `AgentMonitorService` | Stop/SubagentStop có thể để lại approval card; session history tăng theo số phiên. | Xóa pending, thông báo collapse, giới hạn 100 session và drop request bị thay thế/evict. Test pending Stop và 125 session. Các response vẫn giữ schema PermissionRequest/PreToolUse hiện có. |
| A12 / P1 | `ShelfStore`, retention preferences | Metadata cleanup có thể trỏ ra ngoài Shelf hoặc chứa NaN/deadline bất thường; xóa file ngoài khay là đường mất dữ liệu. | Chỉ nhận file có parent chuẩn hóa đúng thư mục Shelf; kiểm tra deadline tối đa 24h; worker kiểm tra lại trước trash. Test đường `..`, prefix gần giống, file ngoài khay và deadline không hữu hạn. Symlink được xử lý như một item trong khay, không xóa target ngoài khay. |
| A13 / P1 | Shelf batch copy | Một copy thất bại có thể để lại destination dở dang và các item của batch trước đó. | Xóa destination dở dang và rollback các copy đã hoàn thành. Test source tồn tại + source mất, source gốc vẫn còn và khay rỗng sau lỗi. Chưa tái hiện đầy ổ đĩa/TCC hoặc filesystem từ xa thật. |
| A14 / P1 | Claude/Codex hook installer | JSON hỏng được xem như config rỗng rồi ghi đè; remove-before-copy có thể mất relay đang hoạt động. | Reader giới hạn 2 MiB, chỉ file regular và cấu trúc hook hợp lệ; lỗi giữ nguyên bytes; deploy script bằng atomic write. Test malformed/wrong-type/oversized config và deploy thất bại giữ script cũ. Không chạy installer lên config thật của người dùng trong audit. |
| A15 / P1 | Codex hook ownership / shell commands | Nhận diện bằng substring hoặc chỉ basename có thể gỡ hook của người dùng; đường dẫn có dấu nháy cần quote đúng. | Chỉ gỡ đúng command của relay tại đường dẫn MNotch hiện tại; dependency command chỉ nội bộ cho test. Test custom command cùng basename và shell roundtrip có apostrophe, newline, `$()` và backtick. Không thay đổi trust database Codex. |
| A16 / P2 | Hai relay Perl | Regex đọc/splice JSON nhầm field lồng nhau, escape control character sai; stdin/reply không giới hạn hoặc peer đóng có thể gây chờ/PIPE. | JSON::PP, input 900.000 byte, envelope 1.000.000 byte, reply 64 KiB, stdin deadline 2s và tổng relay tối đa 60s, bỏ qua SIGPIPE. 7 test chạy script thật với localhost fixture, EOF, oversized và schema phản hồi; lỗi giữ native prompt. |
| A17 / P2 | Artwork decode | Base64/image lớn hoặc hỏng có thể gây CPU/RAM và decode trên UI không cần thiết. | Input decode 12 MiB, tối đa 16 MP, thumbnail 512px trước NSImage/dominant color. Test malformed, oversized và PNG hợp lệ 1024px được downsample. |
| A18 / P1 | Bundle / adapter build | ZIP 1.4 **cục bộ** chứa adapter minOS 26.0 trong app khai báo 15.0. Đây là lỗi phân phối xác minh; trên OS cũ helper có thể không load. Chưa chứng minh lỗi này làm main app crash, và chưa kiểm tra archive public để kết luận tương tự. | Luôn rebuild adapter với target 15.0; verifier kiểm tra mọi Mach-O/slice trong bundle. Fixture minOS 26 bị từ chối. Ứng viên mới: 7 Mach-O đều đáp ứng minOS app. |
| A19 / P1 | `Scripts/build.sh` | Trên Swift 6.4, output mới ở `.build/out/Products/Release`, nhưng đường `.build/arm64-apple-macosx/release` vẫn chứa binary cũ tháng 8. Script cũ có thể đóng gói mã cũ sau một build thành công. | Dùng `swift build --show-bin-path` cho app và Sparkle; so UUID packaged executable với output hiện tại. Test reference UUID khác bị từ chối; đối chiếu thực tế candidate khớp. |
| A20 / P2 | dSYM | Archive cũ không lưu dSYM. Compile/link nhiều `.m` một lệnh xóa temporary object trước dsymutil; đã quan sát warning và dSYM chỉ có UUID, không có debug info. | Giữ adapter `.o`, archive executable/framework dSYM; verifier kiểm tra UUID **và** section DWARF `__debug_info`. Fixture UUID-only/mismatch bị từ chối; cả hai symbol bundle ứng viên hợp lệ. |
| A21 / rủi ro chưa xác minh | Private DisplayServices/CoreBrightness/SkyLight | Có symbol/selector không chứng minh ABI hoặc tính an toàn trên tất cả OS/phần cứng. Chưa tái hiện crash của từng API. | Chặn riêng các đường in-process trước dlopen/unsafeBitCast/call. Allowlist major.minor hiện rỗng; không có nút override thử nghiệm. Test macOS 15/26/27/99 đều bị chặn. Chỉ mở sau ma trận manual bên dưới. |
| A22 / P2 | DEBUG notification hooks / diagnostics | Debug distributed notifications có thể approve/reject mà không có opt-in và dump nội dung nhạy cảm; log context động không cần public. | DEBUG probes mặc định tắt, yêu cầu biến môi trường rõ ràng; dump metadata-only; context agent/media để private. Release không chứa DebugProbe. Export có schema cho enum/number/boolean, ring tối đa 256 event; test allowlist keys và capacity. |
| A23 / P2 dependency | Sparkle | Dependency 2.9.4 thiếu các vá upstream 2.9.6 và cải thiện 2.10.0. Chưa chứng minh MNotch normal-user bị khai thác bởi vấn đề root-process được upstream mô tả. | Pin 2.10.0 và revision trong Package.resolved; compile/test/package đã kiểm tra. Signed-feed/Ed25519/hardened-runtime policy giữ nguyên. Xem nguồn upstream bên dưới. |
| A24 / P2 phân phối | Vendor licensing / CI artifacts | Adapter license chưa được kèm trong app; upload thư mục `.app` trực tiếp có thể mất symlink/permissions qua artifact service. | Kèm license BSD adapter và Sparkle, CI archive app/dSYM bằng ditto trước upload. Không thay đổi license/vendor API. |
| A25 / P1 | App termination / helper lifecycle | App kết thúc trước khi callback KILL hẹn 250 ms chạy, có thể bỏ lại helper không chịu TERM; các lệnh terminal fire-and-forget cũng cần owner chung. | Registry chỉ chứa group do app tạo/xác minh; `applicationWillTerminate` KILL các group đồng bộ, không chờ trên main thread. Chặn launch khi shutdown; normal cancellation vẫn TERM→KILL. Fixture shutdown giết helper mà không cần cancel Task và từ chối launch mới. Không coi Force Quit/crash là đã qua nghiệm thu quit bình thường. |
| A26 / P1 | Claude legacy status-line migration | Substring basename có thể nhận nhầm command của người dùng; JSON backup hỏng bị xem như không có backup rồi xóa config/helper/backup. Backup đọc không giới hạn. | Khớp đúng command/path MNotch; backup giới hạn 2 MiB; chỉ cleanup sau migration đã xác minh và atomic write thành công. JSON hỏng/sai kiểu/quá lớn giữ nguyên config và backup; command custom cùng basename được giữ. Hai regression mới và test khôi phục đầy đủ config cũ. |
| A27 / P1 | Sparkle install / File Tray | Update tự cài khi quit hoặc relaunch có thể cắt ngang copy/removal/retention cleanup hay live drag. Code path cũ không có safety boundary như MFinder. | Coordinator tạm ngừng intake và chờ mọi thao tác được theo dõi; nonmodal wait có Cancel/retry, generation chặn phiên chờ cũ. Cả interactive relaunch và automatic-install-on-quit qua boundary. 5 regression; actual Developer ID update-install vẫn chưa chạy. |
| A28 / P2 | Feed verification / release process | Verifier cũ lấy enclosure đầu tiên dù version cần kiểm tra ở item khác, chỉ kiểm tra URL suffix, không so build/bytes/public key với ZIP. Các bước release rời nhau dễ publish thiếu asset hoặc không giữ exact source/symbols. | Chọn đúng item; kiểm tra key, build, version, host/path, bytes và minOS; authenticate history và từ chối downgrade. Make release/publish local, clean/tag preflight, atomic output/hash manifest, upload vào draft rồi publish. 10 checks mới, gồm Sparkle tool ký thật với khóa fixture; không dùng khóa production hoặc xuất bản trong lần kiểm tra này. |

## Bao phủ theo nhóm tính năng

| Nhóm | Đã kiểm tra | Còn cần thực thi trên thiết bị |
|---|---|---|
| Media | Decode/range/seek, deadlines, preferred-player routing, tổng registration deadline 8s, artwork, queue command 16/coalesce seek, idle code path | Chuyển player/browser/video thật; seek/play liên tục; quyền Automation bị từ chối/thu hồi |
| Audio / display HUD | HAL queue ownership, callbacks, numeric HUD, event-tap safety latch và native fallback; private API gate | AirPods/HDMI/audio driver stall, key repeat, TCC revoke giữa callback; brightness/backlight matrix trước mở gate |
| Bluetooth / pin | Observer/token lifecycle, generation, IOKit ownership, battery thresholds | Reconnect dồn dập, device name/address thay đổi, pin sạc/tháo sạc, low power và HID thật |
| Calendar / Focus | Queue/single-flight, quyền callback muộn, event reload coalesce, clear stale state, Focus đọc file có giới hạn | EventKit/TCC revoke thật, lịch rất lớn/cập nhật dồn dập, DB Focus/FDA và OS schema khác |
| Pomodoro | Transitions, sanitized durations, wall-clock countdown, 100 timer cycles, stopAll reset | Sleep/wake qua ranh giới phase, thay đổi clock và auto-continue dài hạn |
| File Tray | Retention containment, rollback, revision/snapshot, drag-retention code review | File lớn, cancel drag thật, recipient upload chậm, hết dung lượng, quyền mất, volume/network ngắt giữa copy |
| Agent / quota | Auth/socket caps/deadlines, hook schemas, pending resolution, session caps, subprocess and streaming fixtures, 100 Codex cycles | Claude/Codex account/CLI thật, ngắt kết nối/backoff, terminal/iTerm/tmux và prompt end-to-end |
| Settings / onboarding | Numeric/default migration, feature-demand code/tests, diagnostics/localization, menu Quit/Close review | Welcome lần đầu, deny/revoke từng TCC, launch at login, keyboard navigation/accessibility UI |
| Windows / vòng đời | Panel.close/stop, pointer timer cleanup, rebuild coalesce, geometry, occlusion và lock gating | Màn hình tích hợp/ngoài, hot-plug, clamshell, fullscreen/Mission Control, lock/saver, repeated sleep/wake, thoát bằng UI |
| Updater / phân phối | Dependency pin/checksum qua SwiftPM, signed-feed policy review, minOS tất cả binaries, ad-hoc signatures, usable dSYM và licenses | Developer ID/notarization/Gatekeeper, update từ bản cũ, deny quyền / interrupted update, public asset validation |

## Kiểm tra đã thực sự chạy

Host: macOS **27.0 (26A428)**, arm64, Swift **6.4**, Xcode SDK 27.0.

| Kiểm tra | Kết quả |
|---|---|
| Debug regression suite | 98/98; 49 test cũ + 44 stability + 5 update integration |
| Release regression suite | 98/98 |
| Address Sanitizer, chạy riêng | 98/98; không có ASan report |
| Thread Sanitizer, chạy riêng | 98/98; không có TSan data-race report |
| Python script/bundle/soak/update checks | 25/25; gồm ký/verify/tamper bằng Sparkle thật với bundle và khóa fixture |
| Bash syntax, hai Perl helpers, CI YAML, localization/plist lint, diff whitespace | Pass |
| Release assembly và verify | 7 Mach-O; mọi deployment target ≤15.0; app UUID khớp SwiftPM output; 2 dSYM đúng UUID và có debug info; codesign strict/deep verification pass |
| Desktop smoke/profile | Binary mới chạy smoke 90.1s / 18 mẫu, không tự thoát hoặc mất heartbeat. Sau 20s: RSS 69.36–69.39 MiB, CPU 0.5–1.3%, numeric FD 3, child count 0 tại thời điểm lấy mẫu, main-thread tick 4.999431–5.000523s. Profile 2s trên bản sao cùng binary trong soak: 147 mẫu main thread nằm trong AppKit run loop, 145 mẫu chờ Mach port. Đây là kiểm tra idle, chưa chứng minh mọi tương tác đều không treo. |
| Soak 8 giờ | **Đang chạy / chưa nghiệm thu**, bắt đầu 18:46 ngày 02/10/2026 (UTC+7) trên ứng viên có Sparkle; không tính các lượt bị dừng để rebuild. Xem `build/audit/soak-8h-sparkle-2026-10-02/progress.json`; chỉ `result.json` sau đủ thời gian mới là kết quả. |
| macOS 15 / 26 thực tế | **Chưa chạy tại máy này**. CI đã khai báo ma trận, chưa dispatch hoặc nhận kết quả CI |
| Ma trận phần cứng/permission thủ công | **Chưa hoàn tất** |
| Developer ID / notarization / update-install | **Chưa chạy**; ứng viên chỉ ad-hoc, không phải bản public |

Các test ký update dùng bundle fixture và khóa tạm; không chứng minh khóa
production đang sẵn sàng. Lookup public-key metadata từ Keychain đã timeout
sau 10s nên chưa xác nhận match trên máy này, không tạo/đổi/xuất private key.
`make release` sẽ kiểm tra khóa thực tế trước notarization và dừng nếu không
khớp khóa public hiện có. Không chạy `make publish` hoặc chỉnh feed công khai
trong phiên này.

Sanitizer ở đây instrument executable/test Swift; framework Sparkle binary,
framework hệ thống và adapter chạy trong Perl không được instrument bởi các
test này. Không có suppressions để che lỗi. Có log CoreData/Contacts XPC 4097
từ framework hệ thống trong test host; suite vẫn pass. Không diễn giải log này
thành crash MNotch hay bỏ qua như thể toàn bộ môi trường không có cảnh báo.
Adapter test client vẫn có một Clang extension warning về array constant;
client đó không được đóng gói vào ứng viên. Không còn capture warning Swift
trong các lượt build/test cuối.

## Artifacts và tái chạy

- App: `build/MNotch.app`.
- Candidate ZIP: `build/audit/MNotch-1.4.1-audit.zip`.
- Symbols: `build/symbols/1.4.1-audit-90`, và ZIP riêng trong `build/audit`.
- Evidence metadata: `build/audit/evidence.json`; logs kiểm tra lưu cục bộ trong
  `build/audit/checks`. Raw compiler/system logs có thể chứa đường dẫn máy;
  không phải diagnostic export dành cho người dùng.
- Source/patch snapshot nằm trong `build/audit`; workspace chưa commit/publish.
  Archive source dùng file tracked và non-ignored, không bao gồm dữ liệu app.

```sh
swift test --disable-automatic-resolution
swift test -c release --disable-automatic-resolution
swift test --disable-automatic-resolution --sanitize=address
swift test --disable-automatic-resolution --sanitize=thread
python3 -m unittest discover -s Tests/BuildChecks -v
CONFIG=release SIGN_ID=- VERSION=1.4.1-audit Scripts/build.sh
python3 Scripts/soak-test.py build/MNotch.app \
  --output build/audit/soak-new-run --duration 28800 --interval 30
```

Soak harness sao chép app, đổi bundle ID và ad-hoc sign bản sao; dùng thư mục
support riêng qua `MNOTCH_SUPPORT_DIRECTORY`, tắt updater và Agent/quota. Nó
không sửa HOME/CODEX_HOME, config hook hay login của người dùng; không tạo quyền
TCC mới. Quyền mà hệ thống đã cho phép/inherit có thể vẫn hoạt động, được ghi
trong heartbeat. Các tính năng default còn lại và UI idle chạy trên desktop.
Đây không phải soak cho tất cả workload hoặc các private integration đang bị
chặn. Nó chỉ dừng process bản sao do chính harness tạo.

Mỗi 30s đo RSS, CPU, numeric FD, descendant count, tuổi heartbeat và khoảng
main-thread tick; metadata không gồm argv/env/tokens/tên file/nội dung lịch.
Sau warm-up 10 phút cần ít nhất 20 mẫu. So sánh median quý đầu/cuối: tăng RSS
>max(10 MiB, 10% baseline), FD >5 hoặc child >2 yêu cầu xem xét raw CSV. Các
ngưỡng là tín hiệu review, không thay thế phân tích trend. Host sleep/sampler
bị pause dài → inconclusive; heartbeat quá 60s → lỗi health/main thread hoặc
writer, cần sample để phân biệt. Run <8h chỉ có `smoke_completed`; không được
đổi thành soak đạt. Soak đủ thời gian cũng không mở allowlist private API.

## Ma trận nghiệm thu còn lại

Trên **mỗi macOS 15, 26, 27**, ghi patch version, model/SOC, build/UUID và display
configuration; không ghi serial/account. Chạy debug/release, rồi candidate thật:

1. Màn hình tích hợp và ngoài: 100 vòng feature toggle/start/stop, hot-plug,
   clamshell, fullscreen/Mission Control, sleep/wake, lock/unlock, screensaver;
   xác nhận không panel mất, timer/observer/task/socket tăng theo vòng.
2. Đổi AirPods/HDMI và nguồn media; key repeat; disconnect khi helper đang đọc;
   Calendar cập nhật dồn dập; deny rồi revoke Accessibility/Calendar/Bluetooth/
   Automation/FDA. Không để key tap nuốt phím khi service không sẵn sàng.
3. File Tray: copy file lớn/batch, cancel drag, receiver giữ file để upload,
   volume ngắt, hết dung lượng, quyền mất; kiểm tra source/copy/retention thực tế.
4. Agent: hooks end-to-end, malformed/oversized messages, native fallback,
   account quota CLI thật, lost connection, terminal jump và response bị trễ.
5. Soak 8h có workload luân phiên; Instruments Time Profiler/Allocations/Hangs
   kiểm tra stall, RAM, FD, task và subprocess sau warm-up. Current idle soak
   không thay thế bước này.
6. Developer ID, hardened runtime/entitlements, notarization/stapling/Gatekeeper
   và update từ bản public trước đó; giữ exact ZIP + dSYMs + source revision.

Chỉ thêm `PrivateAPICompatibility.verifiedVersions` sau khi các scenario liên
quan vượt qua trên tổ hợp OS/phần cứng cần hỗ trợ. Major.minor allowlist không
phải bảo đảm ABI cho mọi patch; cần kiểm tra lại khi OS cập nhật.

Các vấn đề chức năng/UX còn lại: P2 phản hồi UI khi helper không sẵn sàng (có thể
giữ quota stale/optimistic state đến poll); P2 hủy copy lớn không thể ngắt một
FileManager call đang ở kernel; P2 precision fullscreen/Mission Control heuristic
và lock transition cần đo trên màn hình thật. Chưa có bằng chứng chúng là nguyên
nhân crash; không viết lại kiến trúc/UI để suy đoán xử lý chúng.

## Thu thập báo cáo crash hoặc treo mới

1. **Settings → About → Export Diagnostics**: lưu JSON của phiên vừa gặp lỗi.
   Report chỉ chứa version/build/OS/arm64, boolean service state và tối đa 256
   enum error/status/elapsed events. Không có token, tài khoản, path, tên/nội dung
   file, hội thoại hay calendar title. Không tự upload. Buffer được reset khi
   process khởi động lại, nên JSON sau relaunch không chứa sự kiện trước crash.
2. Nếu app tự thoát: lấy report MNotch `.ips` từ Console → Crash Reports hoặc
   `~/Library/Logs/DiagnosticReports`. Giữ nguyên version/UUID, exception type,
   crashed thread và stack. Crash trong Perl helper cần report của helper đúng
   thời điểm, kèm JSON service diagnostics của app.
3. Nếu “Not Responding”: Activity Monitor → MNotch → **Sample Process** trong
   lúc đang treo; nếu có thể lấy thêm mẫu thứ hai sau vài giây, rồi mới Force
   Quit. Stack giúp phân biệt main-thread block với helper/driver/database.
4. Ghi thao tác trước lỗi, OS/patch, màn hình/audio device vừa thay đổi, quyền
   vừa cấp/thu hồi và khả năng tái hiện. Raw `.ips`/sample hệ thống có thể chứa
   đường dẫn/tên máy; xem và che thông tin cá nhân trước khi chia sẻ công khai.
   Không gửi agent-token, agent config, transcript hoặc file trong Shelf.
5. Nhà phát triển đối chiếu executable/framework UUID với dSYM đã lưu; dùng
   symbols đúng archive, không build lại rồi lấy dSYM khác để symbolicate.

## Nguồn upstream đã kiểm tra

- [Sparkle 2.9.6 security fixes](https://github.com/sparkle-project/Sparkle/releases/tag/2.9.6)
  và [Sparkle 2.10.0](https://github.com/sparkle-project/Sparkle/releases/tag/2.10.0):
  installer/archive hardening, sửa root-process case và các lỗi reliability/macOS 27.
- [GitHub runner labels](https://docs.github.com/en/actions/how-tos/write-workflows/choose-where-workflows-run/choose-the-runner-for-a-job):
  macos-15/macos-26 arm64 dùng cho CI; nhãn không chứng minh job đã chạy.
- [Apple Foundation Process](https://developer.apple.com/documentation/foundation/process):
  terminate gửi tín hiệu dừng, waitUntilExit là blocking. TERM không bảo đảm
  descendant chấp hành; fixture và kiểm tra group trên host là bằng chứng local.

## 2026-10-21 — Khôi phục HUD độ sáng trên host đã kiểm chứng

Candidate `1.4.1-audit9 (100)` mở riêng DisplayServices brightness cho
`Mac17,3 / macOS 27.0.1 / 26A434`. Các model/build/patch khác vẫn bị chặn;
keyboard backlight và SkyLight chưa được mở. Các mô tả allowlist rỗng ở phần
audit trước là trạng thái lịch sử trước lần kiểm chứng này.

- Đối chiếu chữ ký hàm C với [khai báo native của Hammerspoon](https://github.com/Hammerspoon/hammerspoon/blob/master/extensions/brightness/libbrightness.m).
  Symbol có mặt không được dùng làm bằng chứng duy nhất.
- Probe native riêng chạy qua UI: 1.201 reads, 201 writes (100 cặp ±1/64 và
  restore), 0 lỗi, 1,882 giây; P95 call 8,44 ms, max 15,65 ms. Mức ban đầu
  `0.39113664627075195` được khôi phục đúng. Báo cáo ở
  `build/brightness-compat-2026-10-21/hardware-probe.json`.
- `BrightnessHardwareWorker` dùng một serial GCD queue; dlopen, dlsym, đọc/ghi
  XPC không chạy trên main actor hoặc cooperative executor. Service giữ tối
  đa một operation đang chạy và một write target mới nhất. Không dlclose khi
  còn lời gọi đang chạy; stop/start không xếp thêm operation sau call bị treo.
- Lease 2,5 giây hết hạn sẽ trả phím về macOS; pending steps cũ được bỏ khi
  API phục hồi. Lỗi ghi không được tự coi là đã phục hồi chỉ vì đọc thành công.
  Mỗi lần ghi kiểm tra lại đúng active built-in display, không dùng external
  primary display hoặc chuyển một lệnh cũ sang display ID khác.
- 138 tests debug và 64 tests release qua; 8 brightness tests qua Address
  Sanitizer và Thread Sanitizer. Fixtures gồm 1.000 steps coalesce, 100 stop/start khi API bị treo,
  stale completion, deallocation, invalid sample, write failure và display change.
- Probe UI thứ hai compile trực tiếp các file service/worker/policy production:
  1.000 steps và 100 restart cycles qua trên hardware thật, chỉ 4 lần write,
  0 lỗi, 0 hardware calls trên main thread và khôi phục đúng baseline. Xem
  `build/brightness-compat-2026-10-21/service-probe.json`.
- Ngày 2026-10-21, người dùng xác nhận trên bản `1.4.1-audit9 (100)`: phím
  tăng/giảm sáng thay đổi độ sáng thực tế và HUD MNotch hiển thị mượt.
- Khi modifying key tap hoạt động, chỉ thao tác phím chủ động gọi HUD; polling
  không tự hiện HUD do thay đổi ánh sáng môi trường. Observe-only fallback
  vẫn hoạt động khi key tap không có quyền/đang tắt.

Phạm vi bằng chứng hiện tại là host trên, không thay thế ma trận màn hình ngoài,
clamshell/sleep/wake/lock và soak 8 giờ ở phần nghiệm thu production.

## 2026-10-21 — Kín mép dưới của hàng menu

Ảnh người dùng cho thấy khe nhỏ dưới HUD. Trên host `Mac17,3 / macOS 27.0.1
/ 26A434`, NSScreen báo safe-area top 32 pt nhưng hàng menu đang hiện cao
33 pt (Retina 2×). Geometry cũ chỉ lấy 32 pt nên bỏ hở 1 pt nền bên dưới.

- Geometry của màn hình có notch dùng chiều cao lớn hơn giữa safe area và
  hàng menu đang hiện; khi menu ẩn, safe area vẫn là mức tối thiểu. Offset
  chiều cao do người dùng chỉnh vẫn được áp dụng. Màn hình giả notch giữ
  cách đo hiện có.
- Closed notch và HUD cùng dùng chiều cao đã đo, không cộng thêm chiều cao
  khi chuyển sang HUD. Viền tương phản được clip trong shape để phần stroke
  nằm ngoài không tràn xuống dưới mép đã căn.
- 57 CoreLogicTests qua, gồm regression trên màn hình notch thật: nền phủ
  hết hàng menu và cả volume/brightness/keyboard-backlight HUD chỉ nở ngang.
  Các kiểm thử fullscreen HUD/pass-through/dismissal tiếp tục qua.

Candidate: `1.4.1-audit10 (101)`. Bằng chứng build, chữ ký, backup và cài đặt
được lưu ở `build/hud-bottom-edge-2026-10-21/`.

## 2026-10-21 — Nghiệm thu mép HUD trước Sparkle 1.5.2

- Native QA liên kết 89 object từ mã nguồn production đã build/test (không
  thay implementation vẽ notch, HUD, panel hoặc occlusion). Điều khiển bằng
  cửa sổ QA riêng, không ghi âm lượng/độ sáng hoặc đổi quyền hệ thống. App QA
  dùng bundle/preferences/support riêng; không đóng gói các hook QA vào release.
- Đã chụp volume/brightness trên Desktop và trong Space fullscreen thật của
  app QA. Ở hai ảnh fullscreen, production watcher xác nhận `fullscreen`;
  cửa sổ foreground 1470×923 pt trên màn hình 1470×956 pt. HUD có alpha 1,
  passive, rộng 351 pt và cao 33 pt bằng closed notch; safe area là 32 pt.
- Phân tích pixel của cả bốn ảnh Retina: hàng cuối của dải 33 pt là nền/viền
  kín (RGB tối đa 37); hàng ngay dưới đã trong suốt, được công cụ capture
  composite lên trắng (RGB tối thiểu 254). Không có khe nền dọc mép phẳng,
  không có stroke tràn xuống dưới. Bo góc vẫn giữ đúng shape.
- Đóng HUD trong fullscreen thật: watcher vẫn là `fullscreen`, status `closed`,
  panel alpha 0 và passive. Kiểm thử timer/dismissal/fade interruption tiếp
  tục nằm trong CoreLogicTests. Không dùng việc app QA ở Space nền làm bằng
  chứng fullscreen: đã đối chiếu foreground và các window bounds khi chụp.
- Regression render bằng ImageRenderer trên production NotchRootView kiểm tra
  volume/brightness, Desktop/fullscreen, outline bật/tắt, scale 1×/2×: hàng
  đáy opaque và hàng tiếp theo alpha 0. 16 tổ hợp render qua trên host này.
- Ảnh, trạng thái native và kết quả pixel ở `build/hud-release-2026-10-21/`.
  Phép thử này nghiệm thu HUD trên host hiện tại; các giới hạn compatibility
  và ma trận phần cứng ở trên vẫn được giữ nguyên.
- CI ban đầu phát hiện hai vấn đề trong fixture: assertion expiry giả định
  thứ tự resume của các task, và Task trả NSImage không Sendable trên SDK cũ.
  Fixture expiry giữ kiểm tra gia hạn rồi chờ trạng thái đóng với timeout 3s;
  fixture thumbnail giữ ảnh trong reference MainActor thay vì truyền NSImage
  qua Task.value. Không thay đổi code vẽ/HUD hoặc thêm Sendable không an toàn.
