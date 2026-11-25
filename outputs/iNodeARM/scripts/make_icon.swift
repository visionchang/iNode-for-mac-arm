import AppKit

// Editable native drawing, rendered at every macOS icon resolution.
let target=CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath:target,withIntermediateDirectories:true)
func render(_ size:Int)->Data {
    let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:size,pixelsHigh:size,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:bitmap)
    defer {NSGraphicsContext.restoreGraphicsState()}
    let context=NSGraphicsContext.current!.cgContext
    context.scaleBy(x:CGFloat(size)/1024,y:CGFloat(size)/1024)
    let tile=NSBezierPath(roundedRect:NSRect(x:72,y:72,width:880,height:880),xRadius:196,yRadius:196)
    NSGradient(starting:NSColor(calibratedRed:0.08,green:0.58,blue:0.94,alpha:1),ending:NSColor(calibratedRed:0.08,green:0.23,blue:0.63,alpha:1))!.draw(in:tile,angle:65)
    // Three connected nodes form an N, recognizable even at small sizes.
    let line=NSBezierPath()
    line.move(to:NSPoint(x:316,y:326));line.line(to:NSPoint(x:316,y:686))
    line.line(to:NSPoint(x:708,y:338));line.line(to:NSPoint(x:708,y:698))
    line.lineWidth=70;line.lineCapStyle = .round;line.lineJoinStyle = .round
    NSColor.white.setStroke();line.stroke()
    for (x,y) in [(316,326),(316,686),(708,338),(708,698)] {
        let ring=NSBezierPath(ovalIn:NSRect(x:x-74,y:y-74,width:148,height:148))
        NSColor.white.setFill();ring.fill()
        let dot=NSBezierPath(ovalIn:NSRect(x:x-32,y:y-32,width:64,height:64))
        NSColor(calibratedRed:0.14,green:0.73,blue:0.91,alpha:1).setFill();dot.fill()
    }
    return bitmap.representation(using:.png,properties:[:])!
}
for size in [16,32,128,256,512] {
    for scale in [1,2] {
        let suffix=scale==2 ? "@2x" : ""
        try render(size*scale).write(to:URL(fileURLWithPath:target+"/icon_\(size)x\(size)\(suffix).png"))
    }
}
