MNotch — Menubar Round 03

01 Flux: M mềm liền khối.
02 Split: hai mảng bo góc và đường cắt chéo.
03 Orbit: đảo nổi và quỹ đạo nghiêng.
04 Ribbon: N từ một dải gập và một nét tách.
05 Bento: hai mảng nội dung và chấm trạng thái.

Hình học trong options.json dùng chung cho SVG và bản xuất CoreGraphics.
Mỗi thư mục gồm SVG, PDF template 16pt, PNG 16/32/48px trong suốt.
Dùng NSImage.isTemplate=true và size=16x16pt khi tích hợp.
Tạo nguồn: python3 create-options.py
Xuất: swift render.swift <đường dẫn thư mục này>
comparison.png: contact sheet; index.html: preview responsive.

Đây là phương án để lựa chọn; chưa thay icon đang cài.
