MNotch — Menubar options, round 02

01-pure-notch: Notch thuần
02-m-mark: Chữ M (gắn với icon app 01)
03-open-frame: Khung mở
04-negative: Âm bản

Bản vector gốc 16x16. Mỗi option: SVG, template PDF, PNG 16/32/48 px với alpha.
SVG sử dụng currentColor; PDF/PNG là hình đen trên nền trong suốt.
Trong AppKit: NSImage.isTemplate = true; NSImage.size = 16x16 pt.
options.json: hình học dùng chung cho SVG và bản xuất native.
Chạy tạo nguồn: python3 create-options.py
Chạy xuất ảnh/PDF: swift render.swift <đường dẫn thư mục này>

Đây là các phương án mới để chọn; chưa thay tài nguyên app đang cài.
