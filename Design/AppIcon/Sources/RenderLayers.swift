import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
let output=CommandLine.arguments[1]
func color(_ hex:UInt32,_ alpha:CGFloat=1)->CGColor { CGColor(red:CGFloat((hex>>16)&255)/255,green:CGFloat((hex>>8)&255)/255,blue:CGFloat(hex&255)/255,alpha:alpha) }
let outer=CGMutablePath()
outer.move(to:CGPoint(x:345,y:269));outer.addLine(to:CGPoint(x:636,y:269));outer.addCurve(to:CGPoint(x:980,y:627),control1:CGPoint(x:839,y:269),control2:CGPoint(x:980,y:411));outer.addCurve(to:CGPoint(x:636,y:985),control1:CGPoint(x:980,y:844),control2:CGPoint(x:838,y:985));outer.addLine(to:CGPoint(x:345,y:985));outer.addQuadCurve(to:CGPoint(x:293,y:932),control:CGPoint(x:293,y:985));outer.addLine(to:CGPoint(x:293,y:323));outer.addQuadCurve(to:CGPoint(x:345,y:269),control:CGPoint(x:293,y:269));outer.closeSubpath()
let letter=outer.mutableCopy()!
letter.move(to:CGPoint(x:480,y:462));letter.addLine(to:CGPoint(x:480,y:792));letter.addLine(to:CGPoint(x:625,y:792));letter.addCurve(to:CGPoint(x:780,y:627),control1:CGPoint(x:719,y:792),control2:CGPoint(x:780,y:722));letter.addCurve(to:CGPoint(x:625,y:462),control1:CGPoint(x:780,y:533),control2:CGPoint(x:719,y:462));letter.closeSubpath()
func gradient(_ ctx:CGContext,_ stops:[CGColor],_ locs:[CGFloat],_ start:CGPoint,_ end:CGPoint) {
 let g=CGGradient(colorsSpace:CGColorSpace(name:CGColorSpace.sRGB)!,colors:stops as CFArray,locations:locs)!
 ctx.drawLinearGradient(g,start:start,end:end,options:[.drawsBeforeStartLocation,.drawsAfterEndLocation])
}
func render(_ name:String,_ draw:(CGContext)->Void) {
 let ctx=CGContext(data:nil,width:1024,height:1024,bitsPerComponent:8,bytesPerRow:4096,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
 ctx.translateBy(x:0,y:1024);ctx.scaleBy(x:1024.0/1254,y:-1024.0/1254)
 draw(ctx)
 let image=ctx.makeImage()!
 let dest=CGImageDestinationCreateWithURL(URL(fileURLWithPath:output+"/"+name+".png") as CFURL,UTType.png.identifier as CFString,1,nil)!
 CGImageDestinationAddImage(dest,image,nil);CGImageDestinationFinalize(dest)
}
render("02-D-Body") { ctx in
 ctx.translateBy(x:16,y:0);ctx.addPath(letter);ctx.clip(using:.evenOdd)
 gradient(ctx,[color(0xC2DF38),color(0xD8F663),color(0xDEFF71),color(0xC6ED46)],[0,0.28,0.69,1],CGPoint(x:355,y:500),CGPoint(x:956,y:920))
 let p=CGMutablePath();p.move(to:CGPoint(x:293,y:558));p.addCurve(to:CGPoint(x:381,y:493),control1:CGPoint(x:293,y:534),control2:CGPoint(x:326,y:516));p.addLine(to:CGPoint(x:773,y:354));p.addCurve(to:CGPoint(x:946,y:440),control1:CGPoint(x:837,y:333),control2:CGPoint(x:900,y:367));p.addLine(to:CGPoint(x:982,y:540));p.addLine(to:CGPoint(x:293,y:683));p.closeSubpath();ctx.addPath(p);ctx.clip()
 gradient(ctx,[color(0x718C14,0.68),color(0xA6C42C,0)],[0,1],CGPoint(x:600,y:395),CGPoint(x:655,y:539))
}
render("03-D-Fold") { ctx in
 ctx.translateBy(x:16,y:0);ctx.addPath(outer);ctx.clip()
 let p=CGMutablePath();p.move(to:CGPoint(x:345,y:269));p.addLine(to:CGPoint(x:636,y:269));p.addCurve(to:CGPoint(x:938,y:424),control1:CGPoint(x:770,y:269),control2:CGPoint(x:872,y:325));p.addCurve(to:CGPoint(x:777,y:352),control1:CGPoint(x:886,y:361),control2:CGPoint(x:835,y:334));p.addLine(to:CGPoint(x:376,y:500));p.addCurve(to:CGPoint(x:293,y:562),control1:CGPoint(x:326,y:520),control2:CGPoint(x:293,y:539));p.addLine(to:CGPoint(x:293,y:323));p.addQuadCurve(to:CGPoint(x:345,y:269),control:CGPoint(x:293,y:269));p.closeSubpath();ctx.addPath(p);ctx.clip()
 gradient(ctx,[color(0xE4FF82),color(0xDCFB71),color(0xE9FF98)],[0,0.52,1],CGPoint(x:354,y:281),CGPoint(x:782,y:463))
}
