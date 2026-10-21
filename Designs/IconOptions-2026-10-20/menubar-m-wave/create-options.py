from pathlib import Path
import json
import shutil
root=Path(__file__).resolve().parent
def shape(commands,fill=True,width=2):
    return {"commands":commands,"fill":fill,"strokeWidth":width}
def pill(x,y,w,h):
    r=w/2;k=.5522847498
    return shape([["M",x+r,y],["C",x+r+k*r,y,x+w,y+r-k*r,x+w,y+r],
                  ["L",x+w,y+h-r],["C",x+w,y+h-r+k*r,x+r+k*r,y+h,x+r,y+h],
                  ["C",x+r-k*r,y+h,x,y+h-r+k*r,x,y+h-r],["L",x,y+r],
                  ["C",x,y+r-k*r,x+r-k*r,y,x+r,y],["Z"]])
def dot(x,y,r=1):
    k=.5522847498
    return shape([["M",x+r,y],["C",x+r,y+k*r,x+k*r,y+r,x,y+r],
                  ["C",x-k*r,y+r,x-r,y+k*r,x-r,y],
                  ["C",x-r,y-k*r,x-k*r,y-r,x,y-r],
                  ["C",x+k*r,y-r,x+r,y-k*r,x+r,y],["Z"]])
def connected_m(left=1.5,right=8.5):
    return shape([["M",left,12.5],["L",left,3.5],["L",(left+right)/2,8.25],
                  ["L",right,3.5],["L",right,12.5]],False,2)
options=[
 {"id":"01-wave-m","name":"Sóng M","tag":"M tạo từ nhịp thanh","width":18,
  "description":"Năm thanh tạo hai đỉnh M, kết thúc bằng chấm nhỏ.",
  "shapes":[pill(x,(16-h)/2,1.9,h) for x,h in zip([.8,3.6,6.4,9.2,12],[7,11,5,11,7])]+[dot(16.5,8)]},
 {"id":"02-m-pulse","name":"M liền nhịp","tag":"M gọn + nhịp","width":18,
  "description":"M liền nét, nối nhịp với một thanh và một chấm.",
  "shapes":[connected_m(),pill(11.5,5,2,6),dot(16,8)]},
 {"id":"03-segment-m","name":"M tách nét","tag":"M ghép từ các thanh","width":18,
  "description":"Các thanh bo tròn ghép thành M, cùng chất với sóng nhạc.",
  "shapes":[shape([["M",1.75,12.5],["L",1.75,3.5]],False,2.1),
            shape([["M",4.75,3.75],["L",7,8.75],["L",9.25,3.75]],False,2.1),
            shape([["M",12.25,3.5],["L",12.25,12.5]],False,2.1),dot(16.5,8)]},
 {"id":"04-m-wave","name":"M + sóng","tag":"Giữ rõ cả M và sóng","width":24,
  "description":"Giữ M rõ ràng và nhịp thanh âm gần với ảnh tham chiếu.",
  "shapes":[connected_m(1.75,8.75),pill(12,5.25,2,5.5),pill(15.75,4.25,2,7.5),dot(21.25,8)]}
]
def svg(o):
    parts=[]
    for s in o["shapes"]:
        d=" ".join(c[0]+" ".join(str(v) for v in c[1:]) for c in s["commands"])
        style='fill="currentColor"' if s["fill"] else f'fill="none" stroke="currentColor" stroke-width="{s["strokeWidth"]}" stroke-linecap="round" stroke-linejoin="round"'
        parts.append(f'<path d="{d}" {style}/>')
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {o["width"]} 16" width="{o["width"]}" height="16" aria-hidden="true">{"".join(parts)}</svg>'
for o in options:
    d=root/o["id"];d.mkdir(exist_ok=True);(d/"menubar.svg").write_text(svg(o)+"\n")
(root/"options.json").write_text(json.dumps({"canvas":16,"options":options},ensure_ascii=False,indent=2)+"\n")
reference=Path("/var/folders/s0/0n8q_7gx06x7znhk5s3y6yjc0000gn/T/codex-clipboard-0ea88906-43fb-4071-b370-b02297bf151c.png")
if reference.exists():shutil.copy2(reference,root/"reference.png")
cards=[]
for i,o in enumerate(options,1):
    icon=svg(o); w=o["width"]
    cards.append(f'''<article><div class="head"><b>0{i}</b><span>{w} × 16 px</span></div><div class="hero" style="--w:{w*4.5}px">{icon}</div><h2>{o["name"]}</h2><p>{o["description"]}</p><div class="label">TRÊN MENUBAR · CAO 16 PX</div><div class="bar light"><b>MNotch</b><div>{icon}<time>14:28</time></div></div><div class="bar dark"><b>MNotch</b><div>{icon}<time>14:28</time></div></div><div class="scale"><span>Phóng lớn 2×</span><div style="--w:{w*2}px">{icon}</div></div><footer><a href="{o["id"]}/menubar.svg">SVG</a><a href="{o["id"]}/menubar-template.pdf">PDF</a><a href="{o["id"]}/menubar@2x.png">PNG Retina</a></footer></article>''')
html='''<!doctype html><html lang="vi"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>MNotch — M × Sóng nhạc</title><style>
*{box-sizing:border-box}body{margin:0;background:#111317;color:#f1f4fa;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;-webkit-font-smoothing:antialiased}.page{padding:34px 40px 28px;max-width:1320px;margin:auto}.top{display:flex;justify-content:space-between;align-items:center}.brand{font-size:18px;font-weight:650;letter-spacing:-.5px}.edition{color:#758194;font-size:10px;letter-spacing:1.3px}.intro{display:flex;align-items:center;justify-content:space-between;margin:38px 0 32px;gap:25px}h1{font-size:36px;font-weight:600;letter-spacing:-1.3px;margin:0 0 12px}.intro p{margin:0;font-size:13px;line-height:1.7;color:#8c99ad}.reference{display:flex;align-items:center;gap:13px;color:#6e7b90;font-size:10px;white-space:nowrap}.reference img{width:101px;height:68px;object-fit:contain;background:#000;border-radius:12px}.grid{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:18px}article{background:#1b1e25;border:1px solid #303641;padding:20px;border-radius:20px}.head{display:flex;justify-content:space-between;align-items:center}.head b{font-weight:600;font-size:12px;color:#adbaff}.head span{font-size:9px;color:#748094}.hero{height:163px;display:grid;place-items:center;color:#f1f4fb}.hero svg{height:72px;width:var(--w)}h2{font-size:23px;font-weight:550;letter-spacing:-.6px;margin:0 0 12px}article>p{font-size:11px;line-height:1.8;color:#929daf;height:44px;margin:0 0 25px}.label{font-size:8px;color:#68758a;letter-spacing:.3px;margin:0 0 10px}.bar{padding:0 10px;height:34px;display:flex;align-items:center;justify-content:space-between;border-radius:7px;margin-bottom:8px;font-size:9px;gap:8px}.bar b{font-weight:600}.bar>div{display:flex;align-items:center;gap:18px}.bar svg{height:16px;display:block;flex:none}.bar time{font-size:9px}.light{background:#e9ecf2;color:#202632}.dark{background:#111419;border:1px solid #2d333f;color:#f1f4fa}.scale{margin-top:19px;padding-top:16px;border-top:1px solid #2c323e;display:flex;justify-content:space-between;align-items:center;height:52px;font-size:9px;color:#68758a}.scale svg{height:32px;width:var(--w);color:#a9b5c7}footer{padding-top:14px;margin-top:19px;border-top:1px solid #2c323e;display:flex;justify-content:space-between;font-size:9px}footer a{color:#7d8daa;text-decoration:none}.note{display:flex;justify-content:space-between;gap:25px;font-size:10px;color:#68758a;line-height:1.7;margin-top:24px}@media(max-width:1050px){.grid{grid-template-columns:repeat(2,minmax(0,1fr))}.reference{display:none}}@media(max-width:580px){.grid{grid-template-columns:1fr}.page{padding:25px}.edition{font-size:8px}h1{font-size:30px}.note{display:block}}
</style><main class="page"><div class="top"><span class="brand">MNotch</span><span class="edition">M × AUDIO / ROUND 04</span></div><div class="intro"><div><h1>Chữ M có nhịp.</h1><p>Thanh bo tròn, nhịp cao thấp và chấm nhỏ theo ảnh bạn gửi.<br>Bốn cách kết hợp, xem đúng chiều cao menubar 16 px.</p></div><div class="reference">Ảnh tham chiếu<img src="reference.png" alt="Ảnh tham chiếu sóng nhạc do người dùng gửi"></div></div><section class="grid">'''+''.join(cards)+'''</section><div class="note"><span>01 tạo M bằng nhịp thanh · 02 gọn và liền nét · 03 tách nét · 04 gần nhịp của ảnh mẫu</span><span>Cao 16 px · Rộng 18 / 24 px · SVG / PDF / PNG</span></div></main></html>'''
(root/"index.html").write_text(html)
(root/"README.txt").write_text("MNotch — M × Sóng nhạc, round 04\n\n01-wave-m: năm thanh tạo hai đỉnh M + chấm. 18x16pt.\n02-m-pulse: M liền nét + thanh + chấm. 18x16pt.\n03-segment-m: M tách nét + chấm. 18x16pt.\n04-m-wave: M rõ + nhịp thanh và chấm gần ảnh mẫu. 24x16pt.\n\nẢnh gốc người dùng gửi: reference.png, chỉ dùng tham chiếu kiểu thanh bo tròn.\nSVG/PDF vector, PNG có alpha ở 1x/2x/3x.\nKhi tích hợp, giữ tỉ lệ rộng/cao, isTemplate=true, cao 16pt.\nOption 04 cần vùng menubar rộng hơn các option 01–03.\nHình học dùng chung nằm trong options.json.\nTạo nguồn: python3 create-options.py\nXuất: swift render.swift <đường dẫn thư mục này>\nĐây là các phương án để chọn, chưa thay icon đang cài.\n")
print("Created four M + waveform options.")

