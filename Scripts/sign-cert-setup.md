# Tạo cert ký code "MNotch Dev" (làm một lần)

Ad-hoc signing tạo cdhash mới mỗi lần build → macOS coi mỗi bản build là app khác
→ các quyền TCC (Accessibility, Calendar, Bluetooth) bị reset liên tục.
Cert self-signed cho identity ổn định, quyền được giữ qua các lần build.

## Các bước (Keychain Access)

1. Mở **Keychain Access** (Cmd+Space → "Keychain Access").
2. Menu **Keychain Access → Certificate Assistant → Create a Certificate…**
3. Điền:
   - **Name:** `MNotch Dev`
   - **Identity Type:** Self Signed Root
   - **Certificate Type:** **Code Signing**
4. Bấm **Create** → **Done**.
5. (Nếu build báo lỗi trust) Trong Keychain Access, tìm cert `MNotch Dev`
   → double-click → mục **Trust** → **Code Signing: Always Trust** → đóng lại, nhập mật khẩu.

Sau đó `Scripts/build.sh` tự phát hiện cert và dùng nó. Kiểm tra:

```sh
security find-identity -v -p codesigning | grep "MNotch Dev"
```

Lần đầu ký bằng cert này, macOS có thể hỏi cho phép `codesign` truy cập private key —
chọn **Always Allow**.
