from pathlib import Path
import json
import math
import shutil

root = Path(__file__).resolve().parent
def shape(commands, fill=True, width=1.5):
    return {"commands": commands, "fill": fill, "strokeWidth": width}
def rounded_rect(x, y, w, h, r):
    k = 0.5522847498
    return [
        ["M", x+r, y], ["L", x+w-r, y],
        ["C", x+w-r+k*r, y, x+w, y+r-k*r, x+w, y+r],
        ["L", x+w, y+h-r],
        ["C", x+w, y+h-r+k*r, x+w-r+k*r, y+h, x+w-r, y+h],
        ["L", x+r, y+h],
        ["C", x+r-k*r, y+h, x, y+h-r+k*r, x, y+h-r],
        ["L", x, y+r],
        ["C", x, y+r-k*r, x+r-k*r, y, x+r, y], ["Z"]
    ]
def ellipse(cx, cy, rx, ry, angle=0):
    k = 0.5522847498
    raw = [["M", rx, 0], ["C", rx, k*ry, k*rx, ry, 0, ry],
           ["C", -k*rx, ry, -rx, k*ry, -rx, 0],
           ["C", -rx, -k*ry, -k*rx, -ry, 0, -ry],
           ["C", k*rx, -ry, rx, -k*ry, rx, 0], ["Z"]]
    a = math.radians(angle)
    out = []
    for cmd in raw:
        transformed = [cmd[0]]
        for i in range(1, len(cmd), 2):
            x, y = cmd[i], cmd[i+1]
            transformed += [round(cx+x*math.cos(a)-y*math.sin(a), 6),
                            round(cy+x*math.sin(a)+y*math.cos(a), 6)]
        out.append(transformed)
    return out
options = [
    {"id": "01-flux", "name": "Flux", "tag": "M mềm, liền khối",
     "description": "Chữ M với hai vòm cong và khoảng âm rộng.",
     "shapes": [shape([
         ["M",1.25,12.5],["L",1.25,6.2],
         ["C",1.25,3.4,2.85,2,5.05,2],
         ["C",6.45,2,7.45,2.65,8,3.8],
         ["C",8.55,2.65,9.55,2,10.95,2],
         ["C",13.15,2,14.75,3.4,14.75,6.2],["L",14.75,12.5],
         ["C",14.75,13.33,14.08,14,13.25,14],
         ["C",12.42,14,11.75,13.33,11.75,12.5],["L",11.75,6.25],
         ["C",11.75,5.35,11.4,4.9,10.8,4.9],
         ["C",10.2,4.9,9.65,5.4,9.65,6.5],["L",9.65,10.8],
         ["C",9.65,11.7,8.9,12.45,8,12.45],
         ["C",7.1,12.45,6.35,11.7,6.35,10.8],["L",6.35,6.5],
         ["C",6.35,5.4,5.8,4.9,5.2,4.9],
         ["C",4.6,4.9,4.25,5.35,4.25,6.25],["L",4.25,12.5],
         ["C",4.25,13.33,3.58,14,2.75,14],
         ["C",1.92,14,1.25,13.33,1.25,12.5],["Z"]
     ])]},
    {"id": "02-split", "name": "Split", "tag": "Vết cắt chéo",
     "description": "Hai mảng bo góc, ngăn bởi một đường cắt chéo.",
     "shapes": [
         shape([["M",4,1.5],["L",11.5,1.5],
                ["C",12.05,1.5,12.3,2.15,11.9,2.55],["L",2.55,11.9],
                ["C",2.15,12.3,1.5,12.05,1.5,11.5],["L",1.5,4],
                ["C",1.5,2.62,2.62,1.5,4,1.5],["Z"]]),
         shape([["M",12,14.5],["L",4.5,14.5],
                ["C",3.95,14.5,3.7,13.85,4.1,13.45],["L",13.45,4.1],
                ["C",13.85,3.7,14.5,3.95,14.5,4.5],["L",14.5,12],
                ["C",14.5,13.38,13.38,14.5,12,14.5],["Z"]])
     ]},
    {"id": "03-orbit", "name": "Orbit", "tag": "Đảo & quỹ đạo",
     "description": "Một đảo nổi nằm trong quỹ đạo nghiêng.",
     "shapes": [
         shape(ellipse(8,8,6.9,4.6,-35),False,1.5),
         shape(rounded_rect(4.5,6.25,7,3.5,1.75))
     ]},
    {"id": "04-ribbon", "name": "Ribbon", "tag": "N gập liền mạch",
     "description": "Chữ N tạo từ một dải gập và một nét tách.",
     "shapes": [
         shape([["M",2,12.5],["L",2,3.5],
                ["C",2,2.8,2.6,2.25,3.3,2.25],["L",5.2,2.25],
                ["C",5.55,2.25,5.85,2.4,6.05,2.7],["L",13.6,12.1],
                ["C",14.1,12.75,13.65,13.75,12.85,13.75],["L",10.8,13.75],
                ["C",10.45,13.75,10.15,13.6,9.95,13.3],["L",5,7.1],["L",5,12.5],
                ["C",5,13.2,4.45,13.75,3.75,13.75],["L",3.25,13.75],
                ["C",2.55,13.75,2,13.2,2,12.5],["Z"]]),
         shape(rounded_rect(11,2.25,3,5.5,1.5))
     ]},
    {"id": "05-bento", "name": "Bento", "tag": "Widget & trạng thái",
     "description": "Hai mảng nội dung với chấm trạng thái riêng.",
     "shapes": [
         shape(rounded_rect(1.5,1.5,7.75,5.75,2.25)),
         shape(ellipse(12.5,4.375,2.25,2.25)),
         shape(rounded_rect(1.5,8.75,13.25,5.75,2.25))
     ]}
]
def svg(option):
    parts = []
    for s in option["shapes"]:
        d = " ".join(c[0]+" ".join(str(v) for v in c[1:]) for c in s["commands"])
        style = 'fill="currentColor"' if s["fill"] else f'fill="none" stroke="currentColor" stroke-width="{s["strokeWidth"]}" stroke-linejoin="round" stroke-linecap="round"'
        parts.append(f'<path d="{d}" {style}/>')
    return '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" width="16" height="16" aria-hidden="true">'+"".join(parts)+"</svg>"
for o in options:
    d = root / o["id"]; d.mkdir(exist_ok=True)
    (d/"menubar.svg").write_text(svg(o)+"\n")
(root/"options.json").write_text(json.dumps({"canvas":16,"options":options},ensure_ascii=False,indent=2)+"\n")
shutil.copy2(root.parent/"01-peak/app-icon.png",root/"app-icon-reference.png")
cards=[]
for i,o in enumerate(options,1):
    icon=svg(o)
    cards.append(f'''<article><div class="label"><b>0{i}</b><span>{o["tag"]}</span></div><div class="stage">{icon}</div><h2>{o["name"]}</h2><p>{o["description"]}</p><div class="native"><span>KÍCH THƯỚC THỰC</span><span>16 px</span></div><div class="bar light"><b>MNotch</b><div>{icon}<time>14:28</time></div></div><div class="bar dark"><b>MNotch</b><div>{icon}<time>14:28</time></div></div><div class="scale"><span>32 px</span><div>{icon}</div></div><footer><a href="{o['id']}/menubar.svg">SVG</a><a href="{o['id']}/menubar-template.pdf">PDF</a><a href="{o['id']}/menubar-32px.png">PNG Retina</a></footer></article>''')
page='''<!doctype html><html lang="vi"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>MNotch — Menubar Round 03</title><style>
*{box-sizing:border-box}body{margin:0;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;background:#111317;color:#f5f6f8;-webkit-font-smoothing:antialiased}.page{max-width:1500px;padding:34px 40px 28px;margin:auto}.top{display:flex;justify-content:space-between;align-items:center}.brand{display:flex;align-items:center;gap:9px;font-weight:650;font-size:17px;letter-spacing:-.5px}.brand img{width:36px;height:36px}.edition{font-size:10px;color:#787f8b;letter-spacing:1.5px}.intro{margin:40px 0 32px}h1{font-size:36px;font-weight:600;letter-spacing:-1.3px;line-height:1.15;margin:0 0 13px}.intro p{font-size:13px;color:#89909d;line-height:1.7;margin:0}.grid{display:grid;grid-template-columns:repeat(5,minmax(0,1fr));gap:15px}article{border:1px solid #30343e;border-radius:20px;padding:19px;background:#1b1e25}.label{display:flex;justify-content:space-between;gap:5px;align-items:center}.label b{font-size:12px;font-weight:600;color:#adbaff}.label span{font-size:9px;color:#717a89}.stage{height:164px;display:grid;place-items:center;color:#edf0f7}.stage svg{width:74px;height:74px}h2{font-size:25px;font-weight:550;letter-spacing:-.7px;margin:0 0 12px}article>p{font-size:11px;line-height:1.8;color:#9199a8;min-height:42px;margin:0 0 26px}.native{display:flex;justify-content:space-between;font-size:8px;letter-spacing:.35px;color:#687180;margin:0 0 10px}.native span+span{letter-spacing:0}.bar{height:34px;padding:0 9px;display:flex;align-items:center;justify-content:space-between;gap:6px;border-radius:7px;margin:0 0 8px;font-size:9px}.bar b{font-weight:600}.bar>div{display:flex;align-items:center;gap:13px}.bar svg{width:16px;height:16px;display:block}.bar time{font-size:9px}.light{background:#e9ecf2;color:#202632}.dark{background:#111419;border:1px solid #2d323d;color:#f1f4fa}.scale{margin-top:17px;padding-top:14px;border-top:1px solid #2c313b;display:flex;align-items:center;justify-content:space-between;font-size:9px;color:#6b7586;height:51px}.scale svg{width:32px;height:32px;color:#a9b2c1}footer{display:flex;justify-content:space-between;gap:5px;font-size:9px;margin-top:18px;padding-top:14px;border-top:1px solid #2c313b}footer a{color:#7d8daa;text-decoration:none}.note{display:flex;justify-content:space-between;gap:24px;font-size:10px;color:#647083;line-height:1.7;margin-top:23px}@media(max-width:1150px){.grid{grid-template-columns:repeat(3,minmax(0,1fr))}}@media(max-width:780px){.page{padding:25px}.grid{grid-template-columns:repeat(2,minmax(0,1fr))}.edition{font-size:8px}h1{font-size:30px}}@media(max-width:500px){.grid{grid-template-columns:1fr}.note{display:block}}
</style><main class="page"><div class="top"><div class="brand"><img src="app-icon-reference.png" alt="">MNotch</div><span class="edition">MENUBAR / ROUND 03</span></div><div class="intro"><h1>Ít nét hơn. Nhiều cá tính hơn.</h1><p>Năm hướng hình khối mới, có mẫu menubar 16 px trên nền sáng và tối.<br>Bản phóng lớn thể hiện đường cong và khoảng trống của từng thiết kế.</p></div><section class="grid">'''+''.join(cards)+'''</section><div class="note"><span>01 / M mềm &nbsp; 02 / Cắt chéo &nbsp; 03 / Quỹ đạo &nbsp; 04 / Dải gập &nbsp; 05 / Widget</span><span>Đơn sắc · SVG / PDF vector · PNG 16 / 32 / 48 px</span></div></main></html>'''
(root/"index.html").write_text(page)
(root/"README.txt").write_text("MNotch — Menubar Round 03\n\n01 Flux: M mềm liền khối.\n02 Split: hai mảng bo góc và đường cắt chéo.\n03 Orbit: đảo nổi và quỹ đạo nghiêng.\n04 Ribbon: N từ một dải gập và một nét tách.\n05 Bento: hai mảng nội dung và chấm trạng thái.\n\nHình học trong options.json dùng chung cho SVG và bản xuất CoreGraphics.\nMỗi thư mục gồm SVG, PDF template 16pt, PNG 16/32/48px trong suốt.\nDùng NSImage.isTemplate=true và size=16x16pt khi tích hợp.\nTạo nguồn: python3 create-options.py\nXuất: swift render.swift <đường dẫn thư mục này>\ncomparison.png: contact sheet; index.html: preview responsive.\n\nĐây là phương án để lựa chọn; chưa thay icon đang cài.\n")
print("Created 5 modern menubar concepts:",root)

