MNotch icon options — 2026-10-20

01-peak: Núi M
02-notch: Notch tối giản
03-island: Đảo nổi

Mỗi thư mục gồm app-icon.png (bản gốc AI, có alpha), menubar.svg, menubar-template.pdf và PNG 18/36/54 px.
Menubar dùng template đơn sắc, tự đổi màu theo giao diện hệ thống. Khi tích hợp AppKit: isTemplate=true và size=18x18 pt.
index.html: trang so sánh. prompts.json: nguyên văn prompt ImageGen. render-menubar.swift: nguồn xuất vector/raster cho menubar.

App icons: built-in image_gen. Menubar: vector vẽ riêng, không dùng gradient ở kích thước nhỏ.
Đã chọn ngày 2026-10-20: icon app 01-peak + menubar 02-notch.
Chỉnh tiếp theo yêu cầu: menubar 02-notch-square, khung vuông bo góc 16x16 trong canvas 18x18.
Chọn lại ngày 2026-10-21: menubar-m-refined/m-flow, M hẹp 16x16, chân phải nửa và sóng ở giữa.
Tài nguyên tương ứng đã được đưa vào Support/AppIconSource.png,
Support/icon_mnotch.png, Support/AppIcon.icns, Support/MNotch_icon.svg
và Support/menubar-icon.png. Menubar đang dùng kích thước 16x16 pt trong app.
