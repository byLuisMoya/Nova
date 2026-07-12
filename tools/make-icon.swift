import AppKit

// Genera el icono de Nova en distintos estilos.
// Uso:  swift tools/make-icon.swift <salida.png> [estilo]
// estilos: solar (defecto) · neon · outrun · holo

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let style = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "solar"
let size: CGFloat = 1024
let center = CGPoint(x: size/2, y: size/2)

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r/255, green: g/255, blue: b/255, alpha: a)
}
let cs = CGColorSpaceCreateDeviceRGB()

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
let full = CGRect(x: 0, y: 0, width: size, height: size)

// Destello de 4 puntas (sparkle) con lados cóncavos.
func sparklePath(radius R: CGFloat, waist: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let tips: [CGFloat] = [90, 0, -90, 180]
    func pt(_ a: CGFloat, _ r: CGFloat) -> CGPoint {
        CGPoint(x: center.x + cos(a * .pi/180) * r, y: center.y + sin(a * .pi/180) * r)
    }
    p.move(to: pt(tips[0], R))
    for i in 0..<tips.count {
        let next = tips[(i + 1) % tips.count]
        let control = pt(tips[i] - 45, waist)
        p.addQuadCurve(to: pt(next, R), control: control)
    }
    p.closeSubpath()
    return p
}

// Fondo squircle recortado.
let radius = size * 0.2237
ctx.addPath(CGPath(roundedRect: full, cornerWidth: radius, cornerHeight: radius, transform: nil))
ctx.clip()

func fillSparkle(colors: [CGColor], locations: [CGFloat], R: CGFloat = size*0.40, waist: CGFloat = size*0.055) {
    ctx.saveGState()
    ctx.addPath(sparklePath(radius: R, waist: waist))
    ctx.clip()
    let g = CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: locations)!
    ctx.drawRadialGradient(g, startCenter: center, startRadius: 0,
                           endCenter: center, endRadius: R * 1.05, options: [])
    ctx.restoreGState()
}

func coreDot(glow: CGColor, r: CGFloat = size*0.055) {
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 40, color: glow)
    ctx.setFillColor(rgb(255,255,255))
    ctx.fillEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r*2, height: r*2))
    ctx.restoreGState()
}

switch style {

case "neon":
    // Fondo casi negro con toque índigo.
    let bg = CGGradient(colorsSpace: cs, colors: [rgb(18,16,40), rgb(6,5,16)] as CFArray, locations: [0,1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x:0,y:size), end: CGPoint(x:size,y:0), options: [])
    // Glow doble cian + magenta.
    let glow = CGGradient(colorsSpace: cs,
        colors: [rgb(0,229,255,0.55), rgb(255,46,151,0.40), rgb(120,20,120,0.10), rgb(0,0,0,0)] as CFArray,
        locations: [0,0.4,0.7,1])!
    ctx.drawRadialGradient(glow, startCenter: center, startRadius: 0, endCenter: center, endRadius: size*0.5, options: [])
    // Sparkle con degradado cian→magenta (lineal, sobre el recorte).
    ctx.saveGState()
    ctx.addPath(sparklePath(radius: size*0.40, waist: size*0.05)); ctx.clip()
    let ng = CGGradient(colorsSpace: cs, colors: [rgb(120,240,255), rgb(0,229,255), rgb(255,46,151), rgb(200,20,140)] as CFArray, locations: [0,0.35,0.75,1])!
    ctx.drawLinearGradient(ng, start: CGPoint(x:center.x-size*0.4,y:center.y+size*0.4), end: CGPoint(x:center.x+size*0.4,y:center.y-size*0.4), options: [])
    ctx.restoreGState()
    // Borde neón magenta.
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 30, color: rgb(255,46,151,0.9))
    ctx.addPath(sparklePath(radius: size*0.40, waist: size*0.05))
    ctx.setStrokeColor(rgb(255,255,255,0.85)); ctx.setLineWidth(6); ctx.strokePath()
    ctx.restoreGState()
    coreDot(glow: rgb(0,229,255,0.95))

case "outrun":
    // Cielo synthwave: índigo → magenta.
    let sky = CGGradient(colorsSpace: cs, colors: [rgb(26,11,46), rgb(59,16,80), rgb(120,28,90)] as CFArray, locations: [0,0.6,1])!
    ctx.drawLinearGradient(sky, start: CGPoint(x:0,y:size), end: CGPoint(x:0,y:0), options: [])
    let horizon = size*0.44
    // Rejilla en perspectiva bajo el horizonte (cian neón).
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 8, color: rgb(0,229,255,0.7))
    ctx.setStrokeColor(rgb(0,229,255,0.55)); ctx.setLineWidth(3)
    let vanish = CGPoint(x: center.x, y: horizon)
    for k in stride(from: -7, through: 7, by: 1) {
        let x = center.x + CGFloat(k) * size*0.09
        ctx.move(to: vanish); ctx.addLine(to: CGPoint(x: x, y: 0)); ctx.strokePath()
    }
    var y = horizon, gap = size*0.012
    while y > 0 { ctx.move(to: CGPoint(x:0,y:y)); ctx.addLine(to: CGPoint(x:size,y:y)); ctx.strokePath(); y -= gap; gap *= 1.32 }
    ctx.restoreGState()
    // Sol/nova retro sobre el horizonte, con bandas.
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 70, color: rgb(255,120,60,0.8))
    ctx.addPath(sparklePath(radius: size*0.34, waist: size*0.05)); ctx.clip()
    let sun = CGGradient(colorsSpace: cs, colors: [rgb(255,240,180), rgb(255,150,60), rgb(255,46,151)] as CFArray, locations: [0,0.5,1])!
    ctx.drawLinearGradient(sun, start: CGPoint(x:center.x,y:center.y+size*0.34), end: CGPoint(x:center.x,y:center.y-size*0.34), options: [])
    // Bandas oscuras en la mitad inferior del sol.
    ctx.setFillColor(rgb(26,11,46,0.9))
    var by = center.y - size*0.02, bh = size*0.016, bgap = size*0.03
    while by > center.y - size*0.34 { ctx.fill(CGRect(x:0,y:by,width:size,height:bh)); by -= bgap; bgap *= 1.15 }
    ctx.restoreGState()
    coreDot(glow: rgb(255,200,120,0.9), r: size*0.045)

case "holo":
    let bg = CGGradient(colorsSpace: cs, colors: [rgb(14,14,30), rgb(4,4,12)] as CFArray, locations: [0,1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x:0,y:size), end: CGPoint(x:size,y:0), options: [])
    let glow = CGGradient(colorsSpace: cs, colors: [rgb(120,90,255,0.5), rgb(0,229,255,0.25), rgb(0,0,0,0)] as CFArray, locations: [0,0.5,1])!
    ctx.drawRadialGradient(glow, startCenter: center, startRadius: 0, endCenter: center, endRadius: size*0.5, options: [])
    // Anillo orbital inclinado.
    ctx.saveGState()
    ctx.translateBy(x: center.x, y: center.y); ctx.rotate(by: -0.35)
    ctx.setShadow(offset: .zero, blur: 24, color: rgb(0,229,255,0.8))
    ctx.setStrokeColor(rgb(0,229,255,0.9)); ctx.setLineWidth(9)
    ctx.strokeEllipse(in: CGRect(x: -size*0.42, y: -size*0.16, width: size*0.84, height: size*0.32))
    ctx.restoreGState()
    // Sparkle holográfico cian→violeta→magenta.
    ctx.saveGState()
    ctx.addPath(sparklePath(radius: size*0.36, waist: size*0.05)); ctx.clip()
    let hg = CGGradient(colorsSpace: cs, colors: [rgb(180,255,255), rgb(0,229,255), rgb(120,90,255), rgb(255,46,151)] as CFArray, locations: [0,0.35,0.7,1])!
    ctx.drawLinearGradient(hg, start: CGPoint(x:center.x-size*0.36,y:center.y+size*0.36), end: CGPoint(x:center.x+size*0.36,y:center.y-size*0.36), options: [])
    ctx.restoreGState()
    coreDot(glow: rgb(180,255,255,0.95))

default: // "solar" (la actual)
    let bg = CGGradient(colorsSpace: cs, colors: [rgb(24,22,52), rgb(9,8,22), rgb(4,3,12)] as CFArray, locations: [0,0.55,1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x:0,y:size), end: CGPoint(x:size,y:0), options: [])
    let glow = CGGradient(colorsSpace: cs, colors: [rgb(255,138,61,0.85), rgb(229,72,77,0.35), rgb(120,40,120,0.12), rgb(0,0,0,0)] as CFArray, locations: [0,0.35,0.65,1])!
    ctx.drawRadialGradient(glow, startCenter: center, startRadius: 0, endCenter: center, endRadius: size*0.48, options: [])
    ctx.saveGState(); ctx.setShadow(offset: .zero, blur: 60, color: rgb(255,200,120,0.9))
    fillSparkle(colors: [rgb(255,255,255), rgb(255,233,168), rgb(255,138,61), rgb(229,72,77)], locations: [0,0.25,0.6,1])
    ctx.restoreGState()
    coreDot(glow: rgb(255,255,255,0.9))
}

NSGraphicsContext.restoreGraphicsState()
guard let data = rep.representation(using: .png, properties: [:]) else { exit(1) }
try! data.write(to: URL(fileURLWithPath: outPath))
print("Icono (\(style)) → \(outPath)")
