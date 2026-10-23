import AppKit
import CoreGraphics
import Foundation
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
func move(_ p: CGMutablePath, _ x: CGFloat, _ y: CGFloat) { p.move(to: CGPoint(x:x,y:y)) }
func line(_ p: CGMutablePath, _ x: CGFloat, _ y: CGFloat) { p.addLine(to: CGPoint(x:x,y:y)) }
func curve(_ p: CGMutablePath, _ x: CGFloat, _ y: CGFloat, _ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat) {
 p.addCurve(to: CGPoint(x:x,y:y), control1: CGPoint(x:a,y:b), control2: CGPoint(x:c,y:d))
}
func stroke(_ ctx: CGContext, _ path: CGPath, _ width: CGFloat) {
 ctx.setLineWidth(width); ctx.setLineCap(.round); ctx.setLineJoin(.round)
 ctx.addPath(path); ctx.strokePath()
}
func roundRect(_ ctx: CGContext, _ rect: CGRect, _ radius: CGFloat, fill: Bool) {
 let path=CGPath(roundedRect:rect,cornerWidth:radius,cornerHeight:radius,transform:nil)
 ctx.addPath(path)
 if fill { ctx.fillPath() } else { ctx.setLineWidth(1.5); ctx.strokePath() }
}
func draw(_ ctx: CGContext, _ option: Int) {
 ctx.setFillColor(CGColor(gray:0,alpha:1));ctx.setStrokeColor(CGColor(gray:0,alpha:1))
 if option == 1 {
  let p=CGMutablePath()
  move(p,6,2.25);line(p,4.25,2.25)
  curve(p,2.25,4.25,3.145,2.25,2.25,3.145);line(p,2.25,13.75)
  curve(p,4.25,15.75,2.25,14.855,3.145,15.75);line(p,13.75,15.75)
  curve(p,15.75,13.75,14.855,15.75,15.75,14.855);line(p,15.75,4.25)
  curve(p,13.75,2.25,15.75,3.145,14.855,2.25);line(p,12,2.25);line(p,12,3.25)
  curve(p,10.75,4.5,12,4.1,11.5,4.5);line(p,7.25,4.5)
  curve(p,6,3.25,6.5,4.5,6,4.1);p.closeSubpath()
  stroke(ctx,p,1.5)
  let m=CGMutablePath();move(m,4.5,12.75);line(m,7.25,8.75);line(m,9.25,11.25);line(m,11.75,7.25);line(m,14,12.75)
  stroke(ctx,m,1.5)
 } else if option == 2 {
  roundRect(ctx,CGRect(x:1,y:4,width:16,height:10),3,fill:false)
  let p=CGMutablePath();move(p,6,4);line(p,12,4);line(p,12,5.25)
  curve(p,10.25,7,12,6.216,11.216,7);line(p,7.75,7)
  curve(p,6,5.25,6.784,7,6,6.216);p.closeSubpath();ctx.addPath(p);ctx.fillPath()
 } else {
  roundRect(ctx,CGRect(x:0.75,y:4,width:16.5,height:10),5,fill:false)
  roundRect(ctx,CGRect(x:4,y:7.5,width:1.5,height:3),0.75,fill:true)
  roundRect(ctx,CGRect(x:6.5,y:6.5,width:1.5,height:5),0.75,fill:true)
  roundRect(ctx,CGRect(x:9,y:7.75,width:1.5,height:2.5),0.75,fill:true)
  ctx.fillEllipse(in:CGRect(x:12,y:7.75,width:2.5,height:2.5))
 }
}
for (idx,name) in ["01-peak","02-notch","03-island"].enumerated() {
 let out=root.appendingPathComponent(name)
 for scale in [1,2,3] {
  let size=18*scale
  let ctx=CGContext(data:nil,width:size,height:size,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
  ctx.translateBy(x:0,y:CGFloat(size));ctx.scaleBy(x:CGFloat(scale),y:-CGFloat(scale))
  draw(ctx,idx+1)
  let rep=NSBitmapImageRep(cgImage:ctx.makeImage()!)
  try rep.representation(using:.png,properties:[:])!.write(to:out.appendingPathComponent("menubar-\(size)px.png"))
 }
 var box=CGRect(x:0,y:0,width:18,height:18)
 let url=out.appendingPathComponent("menubar-template.pdf")
 let consumer=CGDataConsumer(url:url as CFURL)!
 let pdf=CGContext(consumer:consumer,mediaBox:&box,nil)!
 pdf.beginPDFPage(nil);pdf.translateBy(x:0,y:18);pdf.scaleBy(x:1,y:-1)
 draw(pdf,idx+1);pdf.endPDFPage();pdf.closePDF()
 print("Rendered \(name): 18/36/54 px and vector PDF")
}

