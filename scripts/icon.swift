import AppKit
let size=1024
let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:size,pixelsHigh:size,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:bitmap)
let rect=NSRect(x:56,y:56,width:912,height:912)
let path=NSBezierPath(roundedRect:rect,xRadius:210,yRadius:210)
let gradient=NSGradient(starting:NSColor(calibratedRed:0.08,green:0.17,blue:0.28,alpha:1),ending:NSColor(calibratedRed:0.13,green:0.33,blue:0.45,alpha:1))!
gradient.draw(in:path,angle:45)
let symbol=NSImage(systemSymbolName:"externaldrive",accessibilityDescription:nil)!.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize:500,weight:.medium))!
symbol.isTemplate=false
NSColor.white.setFill()
symbol.draw(in:NSRect(x:240,y:270,width:544,height:480))
let badge=NSBezierPath(ovalIn:NSRect(x:624,y:180,width:245,height:245));NSColor(calibratedRed:0.28,green:0.87,blue:0.65,alpha:1).setFill();badge.fill()
let tick=NSBezierPath();tick.lineWidth=25;tick.lineCapStyle = .round;tick.lineJoinStyle = .round;tick.move(to:NSPoint(x:680,y:300));tick.line(to:NSPoint(x:728,y:252));tick.line(to:NSPoint(x:815,y:350));NSColor(calibratedRed:0.06,green:0.2,blue:0.19,alpha:1).setStroke();tick.stroke()
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
