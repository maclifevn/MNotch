from pathlib import Path
import json
root=Path(__file__).resolve().parent

def shape(commands,fill=True,width=2):
    return {"commands":commands,"fill":fill,"strokeWidth":width}
def pill(x,y,w,h):
    r=w/2;k=.5522847498
    return shape([["M",x+r,y],["C",x+r+k*r,y,x+w,y+r-k*r,x+w,y+r],
                  ["L",x+w,y+h-r],["C",x+w,y+h-r+k*r,x+r+k*r,y+h,x+r,y+h],
                  ["C",x+r-k*r,y+h,x,y+h-r+k*r,x,y+h-r],["L",x,y+r],
                  ["C",x,y+r-k*r,x+r-k*r,y,x+r,y],["Z"]])
def dot(x,y,r=.6):
    k=.5522847498
    return shape([["M",x+r,y],["C",x+r,y+k*r,x+k*r,y+r,x,y+r],
                  ["C",x-k*r,y+r,x-r,y+k*r,x-r,y],
                  ["C",x-r,y-k*r,x-k*r,y-r,x,y-r],
                  ["C",x+k*r,y-r,x+r,y-k*r,x+r,y],["Z"]])

# Stem lengths: left 13.25-2.75=10.5; right 8-2.75=5.25.
# Waveform bounds 3.65..12.35 keep its horizontal center at x=8.
options=[{
    "id":"m-flow","name":"M Flow","tag":"M hẹp · Chân phải nửa","width":16,
    "description":"M thu gọn, chân phải còn một nửa; sóng nằm giữa, nét bo tròn.",
    "shapes":[
        shape([["M",1.75,13.25],["L",1.75,2.75],["L",7.45,6.55],
               ["C",7.78,6.78,8.22,6.78,8.55,6.55],
               ["L",14.25,2.75],["L",14.25,8]],False,1.9),
        pill(3.65,8.25,1.5,5),
        pill(6.15,9.375,1.5,2.75),
        pill(8.65,8.75,1.5,4),
        dot(11.75,10.75)
    ]
}]
def svg(o):
    parts=[]
    for s in o["shapes"]:
        d=" ".join(c[0]+" ".join(str(v) for v in c[1:]) for c in s["commands"])
        style='fill="currentColor"' if s["fill"] else f'fill="none" stroke="currentColor" stroke-width="{s["strokeWidth"]}" stroke-linecap="round" stroke-linejoin="round"'
        parts.append(f'<path d="{d}" {style}/>')
    return '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" width="16" height="16" aria-hidden="true">'+"".join(parts)+'</svg>'
o=options[0];d=root/o["id"];d.mkdir(exist_ok=True)
(d/"menubar.svg").write_text(svg(o)+"\n")
(root/"options.json").write_text(json.dumps({"canvas":16,"options":options},ensure_ascii=False,indent=2)+"\n")
icon=svg(o)
def card(theme,title,note):
    return f'''<article class="{theme}"><div class="head"><span>{title}</span><span>16 × 16 px</span></div><div class="hero">{icon}</div><p>{note}</p><div class="label">TRÊN MENUBAR · KÍCH THƯỚC THỰC</div><div class="bar"><b>MNotch</b><div>{icon}<time>14:28</time></div></div><div class="scale"><span>Phóng lớn 2×</span>{icon}</div></article>'''
page='''<!doctype html><html lang="vi"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>MNotch — M Flow tinh chỉnh</title><style>
*{box-sizing:border-box}body{margin:0;background:#111317;color:#f1f4fa;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;-webkit-font-smoothing:antialiased}.page{max-width:1080px;margin:auto;padding:36px 40px 28px}.top{display:flex;justify-content:space-between;align-items:center}.brand{font-size:18px;font-weight:650}.edition{font-size:10px;letter-spacing:1.4px;color:#758194}.intro{margin:40px 0 30px}h1{font-size:34px;letter-spacing:-1.2px;font-weight:600;line-height:1.2;margin:0 0 13px}.intro p{color:#8b98ac;font-size:13px;line-height:1.7;margin:0}.grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:20px}article{border-radius:20px;padding:22px;border:1px solid #303641}.dark{background:#1b1e25;color:#f1f4fb}.light{background:#f2f4f8;color:#202632;border-color:#e0e5ee}.head{display:flex;align-items:center;justify-content:space-between;font-size:10px;opacity:.55}.hero{height:195px;display:grid;place-items:center}.hero svg{height:96px;width:96px}article>p{font-size:12px;opacity:.55;line-height:1.7;margin:0 0 24px}.label{font-size:8px;letter-spacing:.4px;opacity:.45;margin:0 0 10px}.bar{height:36px;border-radius:8px;padding:0 12px;display:flex;align-items:center;justify-content:space-between;font-size:10px}.bar b{font-weight:600}.bar>div{display:flex;align-items:center;gap:25px}.bar svg{width:16px;height:16px;display:block}.bar time{font-size:10px}.dark .bar{background:#111419;border:1px solid #2d333f}.light .bar{background:#e1e6ee}.scale{border-top:1px solid #8882;padding-top:18px;margin-top:20px;display:flex;align-items:center;justify-content:space-between;font-size:10px;opacity:.55}.scale svg{width:32px;height:32px}.footer{display:flex;justify-content:space-between;gap:25px;font-size:10px;color:#68758a;line-height:1.7;margin-top:24px}.links{display:flex;gap:18px}.links a{color:#8495b8;text-decoration:none}@media(max-width:650px){.grid{grid-template-columns:1fr}.page{padding:25px}h1{font-size:29px}.edition{font-size:8px}.footer{display:block}.links{margin-top:15px}}
</style><main class="page"><div class="top"><span class="brand">MNotch</span><span class="edition">M FLOW / REFINED</span></div><div class="intro"><h1>M gọn, chân phải lửng.</h1><p>Chữ M hẹp hơn, chân phải bằng một nửa chân trái.<br>Sóng nhạc giữ ở giữa, nếp gấp được bo nhẹ cho liền nét.</p></div><section class="grid">'''+card("dark","NỀN TỐI","Nét bo tròn · Khoảng trống thoáng hơn")+card("light","NỀN SÁNG","Sóng nằm giữa · Nhịp ba thanh và chấm")+'''</section><div class="footer"><span>Canvas 16 × 16 · Chân phải ½ · Sóng ở giữa</span><div class="links"><a href="m-flow/menubar.svg">SVG</a><a href="m-flow/menubar-template.pdf">PDF</a><a href="m-flow/menubar@2x.png">PNG Retina</a></div></div></main></html>'''
(root/"index.html").write_text(page)
(root/"README.txt").write_text("MNotch — M Flow, refined\n\nYêu cầu: M hẹp hơn, chân phải bằng một nửa, sóng giữ giữa.\nCanvas: 16x16pt. Chân trái: 10.5 đơn vị; chân phải: 5.25 đơn vị.\nTâm ngang của nhóm sóng: x=8. Nếp gấp cong và đầu nét bo tròn.\nNguồn hình học: options.json. SVG/PDF vector và PNG trong suốt 1x/2x/3x.\nDùng isTemplate=true và NSImage.size=16x16pt khi tích hợp.\nChạy: python3 create-icon.py; swift render.swift <đường dẫn thư mục này>\nĐã chọn ngày 2026-10-21 để thay icon menubar trong project và cài bản test.\n")
print("Created compact M with half-length right stem and centered waveform.")

