from pathlib import Path
import json
import shutil
from html import escape

root = Path(__file__).resolve().parent
def shape(ops, fill=False, width=1.5):
    return {"commands": ops, "fill": fill, "strokeWidth": width}
options = [
    {
        "id": "01-pure-notch", "name": "Notch thuần", "tag": "Gọn nhất",
        "description": "Chỉ giữ dấu notch, bỏ khung bao quanh.",
        "shapes": [shape([
            ["M", 1.5, 3], ["L", 14.5, 3],
            ["C", 15, 3, 15.25, 3.25, 15.25, 3.75],
            ["L", 15.25, 4.25], ["C", 15.25, 4.75, 15, 5, 14.5, 5],
            ["L", 11.5, 5], ["L", 11.5, 8.75],
            ["C", 11.5, 10, 10.5, 11, 9.25, 11],
            ["L", 6.75, 11], ["C", 5.5, 11, 4.5, 10, 4.5, 8.75],
            ["L", 4.5, 5], ["L", 1.5, 5],
            ["C", 1, 5, .75, 4.75, .75, 4.25], ["L", .75, 3.75],
            ["C", .75, 3.25, 1, 3, 1.5, 3], ["Z"]
        ], True)]
    },
    {
        "id": "02-m-mark", "name": "Chữ M", "tag": "Gắn với icon app",
        "description": "Hai đỉnh núi, cùng nhận diện với icon app 01.",
        "shapes": [shape([
            ["M", 1.75, 13.25], ["L", 5.5, 3.75],
            ["L", 8, 9.5], ["L", 11.25, 2.75], ["L", 14.25, 13.25]
        ], width=1.9)]
    },
    {
        "id": "03-open-frame", "name": "Khung mở", "tag": "Nhẹ và thoáng",
        "description": "Bốn góc tách rời, đặt notch ở giữa cạnh trên.",
        "shapes": [
            shape([["M", 4.25, 2], ["L", 3.25, 2],
                   ["C", 2.55, 2, 2, 2.55, 2, 3.25], ["L", 2, 5.25]]),
            shape([["M", 11.75, 2], ["L", 12.75, 2],
                   ["C", 13.45, 2, 14, 2.55, 14, 3.25], ["L", 14, 5.25]]),
            shape([["M", 14, 10.75], ["L", 14, 12.75],
                   ["C", 14, 13.45, 13.45, 14, 12.75, 14], ["L", 10.75, 14]]),
            shape([["M", 5.25, 14], ["L", 3.25, 14],
                   ["C", 2.55, 14, 2, 13.45, 2, 12.75], ["L", 2, 10.75]]),
            shape([["M", 6, 1.25], ["L", 10, 1.25], ["L", 10, 3.5],
                   ["C", 10, 4.6, 9.6, 5, 8.5, 5], ["L", 7.5, 5],
                   ["C", 6.4, 5, 6, 4.6, 6, 3.5], ["Z"]], True)
        ]
    },
    {
        "id": "04-negative", "name": "Âm bản", "tag": "Đậm và rõ",
        "description": "Khối vuông đặc với notch khoét âm ở phía trên.",
        "shapes": [shape([
            ["M", 5.5, 1], ["L", 5.5, 3.25],
            ["C", 5.5, 4.2, 6.3, 5, 7.25, 5], ["L", 8.75, 5],
            ["C", 9.7, 5, 10.5, 4.2, 10.5, 3.25], ["L", 10.5, 1],
            ["L", 12, 1], ["C", 13.65, 1, 15, 2.35, 15, 4],
            ["L", 15, 12], ["C", 15, 13.65, 13.65, 15, 12, 15],
            ["L", 4, 15], ["C", 2.35, 15, 1, 13.65, 1, 12],
            ["L", 1, 4], ["C", 1, 2.35, 2.35, 1, 4, 1], ["Z"]
        ], True)]
    }
]
def paths(option):
    parts = []
    for s in option["shapes"]:
        d = " ".join(cmd[0] + (" ".join(str(v) for v in cmd[1:])) for cmd in s["commands"])
        style = 'fill="currentColor"' if s["fill"] else f'fill="none" stroke="currentColor" stroke-width="{s["strokeWidth"]}" stroke-linecap="round" stroke-linejoin="round"'
        parts.append(f'<path d="{d}" {style}/>')
    return "".join(parts)
def svg(option):
    return '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" width="16" height="16" aria-hidden="true">' + paths(option) + '</svg>'
for option in options:
    d = root / option["id"]
    d.mkdir(exist_ok=True)
    (d / "menubar.svg").write_text(svg(option) + "\n")
(root / "options.json").write_text(json.dumps({"canvas": 16, "options": options}, ensure_ascii=False, indent=2) + "\n")
shutil.copy2(root.parent / "01-peak/app-icon.png", root / "app-icon-reference.png")
shutil.copy2(root.parent / "02-notch-square/menubar.svg", root / "current-menubar.svg")
wifi = '<svg viewBox="0 0 16 16" class="wifi"><path d="M2 6Q8 1 14 6M4.5 8.5Q8 5.5 11.5 8.5M6.7 11Q8 9.8 9.3 11" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"/><circle cx="8" cy="12.6" r=".8" fill="currentColor"/></svg>'
battery = '<svg viewBox="0 0 20 12" class="battery"><rect x="1" y="2.5" width="15" height="7" rx="2" fill="none" stroke="currentColor"/><rect x="3" y="4.5" width="9" height="3" rx=".6" fill="currentColor"/><path d="M18 5V7" stroke="currentColor" stroke-linecap="round"/></svg>'
cards = []
for i, option in enumerate(options, 1):
    icon = svg(option)
    menu = lambda theme: f'<div class="menu {theme}"><b>MNotch</b><span class="menu-icons">{icon}{wifi}{battery}<time>14:28</time></span></div>'
    cards.append(f'''<article class="card"><div class="card-top"><span class="number">0{i}</span><span class="tag">{option["tag"]}</span></div><div class="hero">{icon}</div><h2>{option["name"]}</h2><p>{option["description"]}</p><div class="native-label"><span>TRÊN MENUBAR</span><span>16 px thực tế</span></div>{menu("light")}{menu("dark")}<div class="size-row"><span>16 px</span><div class="sample s16">{icon}</div><span>32 px</span><div class="sample s32">{icon}</div></div><div class="downloads"><a href="{option["id"]}/menubar.svg">SVG</a><a href="{option["id"]}/menubar-template.pdf">PDF</a><a href="{option["id"]}/menubar-32px.png">PNG Retina</a></div></article>''')
page = '''<!doctype html><html lang="vi"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>MNotch — Menubar options mới</title><style>
*{box-sizing:border-box}body{margin:0;background:#f4f5f8;color:#20242d;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;-webkit-font-smoothing:antialiased}.page{max-width:1320px;margin:auto;padding:36px 40px 28px}.top{display:flex;align-items:center;justify-content:space-between}.brand{display:flex;align-items:center;gap:9px;font-size:17px;font-weight:700;letter-spacing:-.4px}.brand img{width:38px;height:38px}.edition{font-size:10px;font-weight:600;letter-spacing:1.5px;color:#8c93a2}.intro{margin:28px 0 28px;display:flex;justify-content:space-between;align-items:end}h1{font-size:34px;line-height:1.2;letter-spacing:-1.25px;margin:0 0 9px}.subtitle{font-size:13px;color:#7a8291;margin:0;line-height:1.7}.current{display:flex;align-items:center;gap:12px;font-size:11px;color:#9aA1ad;white-space:nowrap;padding-bottom:5px}.current span{display:grid;place-items:center;width:34px;height:34px;background:#e9ecf2;border-radius:8px}.current img{width:16px;height:16px;opacity:.5}.grid{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:16px}.card{background:#fff;border:1px solid #e0e4ed;border-radius:20px;padding:20px;box-shadow:0 5px 20px #34405903}.card-top{display:flex;align-items:center;justify-content:space-between;gap:6px}.number{font-weight:700;font-size:13px;color:#4667b6}.tag{font-size:9px;font-weight:500;color:#838d9e;background:#f2f4f8;padding:5px 7px;border-radius:6px}.hero{height:155px;display:grid;place-items:center;color:#272f3c}.hero svg{width:72px;height:72px}h2{font-size:22px;letter-spacing:-.5px;margin:0 0 10px}.card>p{font-size:12px;line-height:1.7;color:#828b9b;min-height:43px;margin:0 0 25px}.native-label{display:flex;justify-content:space-between;font-size:8px;letter-spacing:.5px;color:#9da4b0;margin-bottom:10px}.native-label span+span{letter-spacing:0}.menu{display:flex;align-items:center;justify-content:space-between;height:35px;border-radius:7px;padding:0 9px;font-size:9px;margin:0 0 8px;gap:8px}.menu b{font-weight:650}.menu-icons{display:flex;align-items:center;gap:9px}.menu-icons>svg{width:16px;height:16px;display:block;flex:none}.menu-icons>svg.wifi{width:13px;height:13px}.menu-icons>svg.battery{width:17px;height:10px}.menu time{font-size:9px}.light{background:#edf0f6;border:1px solid #e6e9f0;color:#292e38}.dark{background:#242833;border:1px solid #292d38;color:#f6f8fc}.size-row{margin-top:19px;border-top:1px solid #eef0f5;padding-top:17px;display:flex;align-items:center;justify-content:space-between;height:55px;gap:7px}.size-row>span{color:#929aaa;font-size:9px}.sample{color:#454d5d;display:grid;place-items:center}.s16 svg{width:16px;height:16px}.s32 svg{width:32px;height:32px}.downloads{display:flex;justify-content:center;gap:14px;font-size:9px;margin-top:20px;padding-top:14px;border-top:1px solid #f0f2f7}.downloads a{color:#6e80a7;text-decoration:none}.footer{display:flex;justify-content:space-between;font-size:10px;color:#8d95a4;line-height:1.7;margin-top:22px;gap:24px}.footer b{font-weight:600;color:#68758e}@media(max-width:1050px){.grid{grid-template-columns:repeat(2,minmax(0,1fr))}.page{padding:30px}.intro{gap:20px}h1{font-size:30px}}@media(max-width:600px){.grid{grid-template-columns:1fr}.page{padding:22px}.edition{font-size:8px}.intro{display:block}.current{margin-top:15px}.footer{display:block}}
</style><main class="page"><div class="top"><div class="brand"><img src="app-icon-reference.png" alt="">MNotch</div><span class="edition">MENUBAR EXPLORATION / ROUND 02</span></div><div class="intro"><div><h1>4 hướng menubar mới.</h1><p class="subtitle">Nét đơn sắc. Dễ nhận ra ở kích thước nhỏ.<br>Mỗi phương án có bản phóng lớn và mẫu trên nền sáng / tối.</p></div><div class="current">Bản đang dùng <span><img src="current-menubar.svg" alt="Icon menubar hiện tại"></span></div></div><section class="grid">''' + "".join(cards) + '''</section><div class="footer"><span><b>Gợi ý:</b> 02 đồng bộ với icon app · 03 thoáng và nhẹ hơn khung kín</span><span>SVG + PDF vector · PNG 16 / 32 / 48 px</span></div></main></html>'''
(root / "index.html").write_text(page)
(root / "README.txt").write_text("MNotch — Menubar options, round 02\n\n01-pure-notch: Notch thuần\n02-m-mark: Chữ M (gắn với icon app 01)\n03-open-frame: Khung mở\n04-negative: Âm bản\n\nBản vector gốc 16x16. Mỗi option: SVG, template PDF, PNG 16/32/48 px với alpha.\nSVG sử dụng currentColor; PDF/PNG là hình đen trên nền trong suốt.\nTrong AppKit: NSImage.isTemplate = true; NSImage.size = 16x16 pt.\noptions.json: hình học dùng chung cho SVG và bản xuất native.\nChạy tạo nguồn: python3 create-options.py\nChạy xuất ảnh/PDF: swift render.swift <đường dẫn thư mục này>\n\nĐây là các phương án mới để chọn; chưa thay tài nguyên app đang cài.\n")
print("Saved 4 new vector designs and comparison page:", root)

