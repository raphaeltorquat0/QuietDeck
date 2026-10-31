import AppKit
import SceneKit
import SwiftUI

/// Steam Deck procedural em SceneKit. Sem malha de terceiros: tudo é gerado aqui, nas proporções reais.
/// Unidade: 1 = 66,5 mm (o corpo tem 4,48 × 1,75, os 298 × 117 mm do aparelho).
@MainActor enum DeckModel {
    private static let scale: CGFloat = 0.01
    /// Coordenadas no plano frontal, origem no canto superior esquerdo, em centésimos de unidade.
    private static func x(_ v: CGFloat) -> CGFloat { (v - 224) * scale }
    private static func y(_ v: CGFloat) -> CGFloat { (92 - v) * scale }

    private static func material(_ color: NSColor, roughness: CGFloat, metalness: CGFloat = 0) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = color
        m.roughness.contents = roughness
        m.metalness.contents = metalness
        return m
    }

    private static let shell = material(NSColor(white: 0.085, alpha: 1), roughness: 0.62)
    private static let rubber = material(NSColor(white: 0.05, alpha: 1), roughness: 0.82)
    private static let plastic = material(NSColor(white: 0.11, alpha: 1), roughness: 0.42)
    private static let controls = material(NSColor(white: 0.19, alpha: 1), roughness: 0.36)
    private static let pad = material(NSColor(white: 0.135, alpha: 1), roughness: 0.55)
    private static let glass = material(NSColor(white: 0.012, alpha: 1), roughness: 0.08)

    private static func roundedPath(_ rect: CGRect, top: CGFloat, bottom: CGFloat) -> NSBezierPath {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: rect.minX + bottom, y: rect.minY))
        p.line(to: NSPoint(x: rect.maxX - bottom, y: rect.minY))
        p.appendArc(withCenter: NSPoint(x: rect.maxX - bottom, y: rect.minY + bottom), radius: bottom, startAngle: 270, endAngle: 360)
        p.line(to: NSPoint(x: rect.maxX, y: rect.maxY - top))
        p.appendArc(withCenter: NSPoint(x: rect.maxX - top, y: rect.maxY - top), radius: top, startAngle: 0, endAngle: 90)
        p.line(to: NSPoint(x: rect.minX + top, y: rect.maxY))
        p.appendArc(withCenter: NSPoint(x: rect.minX + top, y: rect.maxY - top), radius: top, startAngle: 90, endAngle: 180)
        p.line(to: NSPoint(x: rect.minX, y: rect.minY + bottom))
        p.appendArc(withCenter: NSPoint(x: rect.minX + bottom, y: rect.minY + bottom), radius: bottom, startAngle: 180, endAngle: 270)
        p.close()
        p.flatness = 0.002
        return p
    }

    private static func slab(_ path: NSBezierPath, depth: CGFloat, chamfer: CGFloat, _ m: SCNMaterial, z: CGFloat) -> SCNNode {
        // Sem isto o SceneKit aproxima as curvas com poucos segmentos e os cantos ficam facetados.
        path.flatness = 0.0015
        let s = SCNShape(path: path, extrusionDepth: depth)
        s.chamferRadius = chamfer
        s.chamferMode = .both
        s.firstMaterial = m
        let n = SCNNode(geometry: s)
        n.position.z = z
        return n
    }

    private static func disc(_ radius: CGFloat, height: CGFloat, _ m: SCNMaterial, chamfer: CGFloat = 0) -> SCNNode {
        let g = SCNCylinder(radius: radius, height: height)
        g.radialSegmentCount = 72
        g.firstMaterial = m
        let n = SCNNode(geometry: g)
        n.eulerAngles.x = .pi / 2
        return n
    }

    /// Rótulo pequeno em textura, para botões e pílulas.
    private static func label(_ text: String, size: CGSize, font: CGFloat, weight: NSFont.Weight = .bold) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: font, weight: weight), .foregroundColor: NSColor(white: 0.82, alpha: 1)]
            let t = NSAttributedString(string: text, attributes: a)
            let b = t.size()
            t.draw(at: NSPoint(x: (rect.width - b.width) / 2, y: (rect.height - b.height) / 2))
            return true
        }
    }

    private static func pill(_ cx: CGFloat, _ cy: CGFloat, _ w: CGFloat, _ h: CGFloat, text: String, front: CGFloat) -> SCNNode {
        let r = CGRect(x: x(cx) - w * scale / 2, y: y(cy) - h * scale / 2, width: w * scale, height: h * scale)
        let n = slab(NSBezierPath(roundedRect: r, xRadius: h * scale / 2, yRadius: h * scale / 2), depth: 0.022, chamfer: 0.006, plastic, z: front + 0.008)
        let face = SCNPlane(width: r.width * 0.9, height: r.height * 0.9)
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = label(text, size: CGSize(width: r.width * 700, height: r.height * 700), font: r.height * 340)
        m.isDoubleSided = false
        m.writesToDepthBuffer = false
        face.firstMaterial = m
        let f = SCNNode(geometry: face)
        f.position = SCNVector3(r.midX, r.midY, 0.022)
        n.addChildNode(f)
        return n
    }

    private static func stick(_ cx: CGFloat, _ cy: CGFloat, front: CGFloat) -> SCNNode {
        let n = SCNNode()
        n.position = SCNVector3(x(cx), y(cy), front)
        let well = SCNTube(innerRadius: 0.125, outerRadius: 0.15, height: 0.012)
        well.radialSegmentCount = 72
        well.firstMaterial = plastic
        let wellNode = SCNNode(geometry: well)
        wellNode.eulerAngles.x = .pi / 2
        wellNode.position.z = 0.004
        n.addChildNode(wellNode)
        let shaft = disc(0.075, height: 0.09, rubber)
        shaft.position.z = 0.05
        n.addChildNode(shaft)
        let cap = disc(0.112, height: 0.05, rubber)
        cap.position.z = 0.115
        n.addChildNode(cap)
        let rim = SCNTorus(ringRadius: 0.098, pipeRadius: 0.016)
        rim.ringSegmentCount = 72
        rim.firstMaterial = plastic
        let rimNode = SCNNode(geometry: rim)
        rimNode.eulerAngles.x = .pi / 2
        rimNode.position.z = 0.14
        n.addChildNode(rimNode)
        return n
    }

    private static func dpad(_ cx: CGFloat, _ cy: CGFloat, front: CGFloat) -> SCNNode {
        let a: CGFloat = 0.165, b: CGFloat = 0.053
        let p = NSBezierPath()
        let points: [(CGFloat, CGFloat)] = [(-b, a), (b, a), (b, b), (a, b), (a, -b), (b, -b), (b, -a), (-b, -a), (-b, -b), (-a, -b), (-a, b), (-b, b)]
        p.move(to: NSPoint(x: points[0].0, y: points[0].1))
        points.dropFirst().forEach { p.line(to: NSPoint(x: $0.0, y: $0.1)) }
        p.close()
        let n = slab(p, depth: 0.05, chamfer: 0.014, controls, z: 0.02)
        let holder = SCNNode()
        holder.position = SCNVector3(x(cx), y(cy), front)
        holder.addChildNode(n)
        return holder
    }

    private static func faceButton(_ text: String, _ cx: CGFloat, _ cy: CGFloat, front: CGFloat) -> SCNNode {
        let n = disc(0.058, height: 0.045, controls)
        let holder = SCNNode()
        holder.position = SCNVector3(x(cx), y(cy), front + 0.02)
        holder.addChildNode(n)
        let plane = SCNPlane(width: 0.09, height: 0.09)
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = label(text, size: CGSize(width: 90, height: 90), font: 58, weight: .semibold)
        m.writesToDepthBuffer = false
        plane.firstMaterial = m
        let f = SCNNode(geometry: plane)
        f.position.z = 0.0235
        holder.addChildNode(f)
        return holder
    }

    private static func trackpad(_ left: CGFloat, front: CGFloat) -> SCNNode {
        let r = CGRect(x: x(left), y: y(115), width: 0.48, height: 0.48)
        return slab(NSBezierPath(roundedRect: r, xRadius: 0.075, yRadius: 0.075), depth: 0.012, chamfer: 0.005, pad, z: front - 0.001)
    }

    /// Gatilhos: acompanham o canto do corpo e ficam atrás dele, sem pontas soltas.
    private static func bumper(_ from: CGFloat, front: CGFloat) -> SCNNode {
        let r = CGRect(x: x(from), y: y(40), width: 0.66, height: 0.36)
        let path = NSBezierPath(roundedRect: r, xRadius: 0.17, yRadius: 0.17)
        return slab(path, depth: 0.2, chamfer: 0.06, rubber, z: front - 0.27)
    }

    static let screenNodeName = "screen"
    static let steamNodeName = "steam"

    static func build() -> SCNNode {
        let root = SCNNode()
        let depth: CGFloat = 0.34
        let front = depth / 2 + 0.03

        let body = roundedPath(CGRect(x: -2.24, y: -0.88, width: 4.48, height: 1.75), top: 0.32, bottom: 0.47)
        root.addChildNode(slab(body, depth: depth, chamfer: 0.06, shell, z: 0))

        // Pegas traseiras: o volume que as mãos seguram.
        for side in [-1.0, 1.0] as [CGFloat] {
            let grip = roundedPath(CGRect(x: side < 0 ? -2.16 : 1.12, y: -0.84, width: 1.04, height: 1.5), top: 0.24, bottom: 0.46)
            root.addChildNode(slab(grip, depth: 0.3, chamfer: 0.14, shell, z: -0.24))
        }

        root.addChildNode(bumper(5, front: front))
        root.addChildNode(bumper(377, front: front))
        for bx in [112, 130, 330] as [CGFloat] {
            let r = CGRect(x: x(bx), y: y(4.5), width: 0.13, height: 0.03)
            root.addChildNode(slab(NSBezierPath(roundedRect: r, xRadius: 0.012, yRadius: 0.012), depth: 0.06, chamfer: 0.008, plastic, z: 0.02))
        }

        // Moldura de vidro de ponta a ponta do painel central, com a tela dentro.
        let bezel = CGRect(x: x(102), y: y(168), width: 2.42, height: 1.52)
        root.addChildNode(slab(NSBezierPath(roundedRect: bezel, xRadius: 0.035, yRadius: 0.035), depth: 0.012, chamfer: 0.004, glass, z: front))
        let display = SCNPlane(width: 2.2, height: 1.375)
        let screen = SCNMaterial()
        screen.lightingModel = .constant
        screen.diffuse.contents = NSColor.black
        display.firstMaterial = screen
        let displayNode = SCNNode(geometry: display)
        displayNode.name = screenNodeName
        displayNode.position = SCNVector3(bezel.midX, bezel.midY, front + 0.0135)
        root.addChildNode(displayNode)

        root.addChildNode(dpad(27, 34, front: front))
        root.addChildNode(stick(69, 40, front: front))
        root.addChildNode(trackpad(41, front: front))
        root.addChildNode(pill(53, 16, 15, 7, text: "▣", front: front))
        let steam = pill(77, 128, 25, 10, text: "STEAM", front: front)
        steam.name = steamNodeName
        root.addChildNode(steam)

        root.addChildNode(stick(377, 40, front: front))
        root.addChildNode(trackpad(358, front: front))
        root.addChildNode(pill(396, 16, 15, 7, text: "≡", front: front))
        root.addChildNode(pill(371, 128, 25, 10, text: "•••", front: front))
        for (t, bx, by) in [("Y", 420.0, 18.5), ("X", 406.5, 31.5), ("B", 433.5, 31.5), ("A", 420.0, 44.5)] as [(String, CGFloat, CGFloat)] {
            root.addChildNode(faceButton(t, bx, by, front: front))
        }
        return root
    }

    /// Reflexo de estúdio: dá forma às superfícies escuras sem precisar de arquivo HDR.
    private static let studio: NSImage = NSImage(size: NSSize(width: 256, height: 128), flipped: false) { rect in
        NSGradient(colors: [NSColor(white: 0.05, alpha: 1), NSColor(white: 0.34, alpha: 1), NSColor(white: 0.9, alpha: 1)],
                   atLocations: [0, 0.6, 1], colorSpace: .sRGB)?.draw(in: rect, angle: 90)
        return true
    }

    static func scene() -> (scene: SCNScene, deck: SCNNode, screen: SCNMaterial?, steam: SCNNode?) {
        let scene = SCNScene()
        scene.background.contents = NSColor.clear
        scene.lightingEnvironment.contents = studio
        scene.lightingEnvironment.intensity = 1.5

        let deck = build()
        deck.eulerAngles = SCNVector3(-0.16, -0.2, 0)
        scene.rootNode.addChildNode(deck)

        let camera = SCNCamera()
        camera.fieldOfView = 18
        camera.wantsHDR = false
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 0.06, 8.3)
        scene.rootNode.addChildNode(cameraNode)

        let key = SCNLight()
        key.type = .directional
        key.intensity = 650
        key.castsShadow = true
        key.shadowRadius = 8
        let keyNode = SCNNode()
        keyNode.light = key
        keyNode.eulerAngles = SCNVector3(-0.8, -0.4, 0)
        scene.rootNode.addChildNode(keyNode)

        let rim = SCNLight()
        rim.type = .directional
        rim.intensity = 260
        let rimNode = SCNNode()
        rimNode.light = rim
        rimNode.eulerAngles = SCNVector3(0.5, 2.6, 0)
        scene.rootNode.addChildNode(rimNode)

        let screen = deck.childNode(withName: screenNodeName, recursively: true)?.geometry?.firstMaterial
        return (scene, deck, screen, deck.childNode(withName: steamNodeName, recursively: true))
    }

    /// Imagem estática para estados vazios: uma cena viva em cada um gastaria GPU à toa.
    static let still: NSImage = {
        let parts = scene()
        let renderer = SCNRenderer(device: nil, options: nil)
        renderer.scene = parts.scene
        renderer.autoenablesDefaultLighting = false
        return renderer.snapshot(atTime: 0, with: CGSize(width: 760, height: 330), antialiasingMode: .multisampling4X)
    }()
}

/// O modelo na tela. `screen` é desenhada na tela do Deck; `screenID` diz quando redesenhar.
struct Deck3DView<Screen: View>: NSViewRepresentable {
    var screenID: String
    var pulseSteam = false
    @ViewBuilder var screen: Screen

    @MainActor final class Coordinator: NSObject {
        var material: SCNMaterial?
        var steam: SCNNode?
        var deck: SCNNode?
        var lastID: String?
        var pulsing = false

        @objc func pan(_ g: NSPanGestureRecognizer) {
            guard let deck, let view = g.view else { return }
            let t = g.translation(in: view)
            if g.state == .began { deck.removeAction(forKey: "sway") }
            if g.state == .changed {
                deck.eulerAngles.y = -0.2 + CGFloat(t.x) * 0.008
                deck.eulerAngles.x = -0.16 - CGFloat(t.y) * 0.006
            }
            if g.state == .ended || g.state == .cancelled {
                let back = SCNAction.rotateTo(x: -0.16, y: -0.2, z: 0, duration: Motion.reduced ? 0 : 0.28)
                back.timingMode = .easeOut
                deck.runAction(back)
                Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(320))
                    self?.startSway()
                }
            }
        }

        func startSway() {
            guard !Motion.reduced, let deck else { return }
            let a = SCNAction.rotateTo(x: -0.16, y: -0.1, z: 0, duration: 5)
            let b = SCNAction.rotateTo(x: -0.16, y: -0.3, z: 0, duration: 5)
            a.timingMode = .easeInEaseOut
            b.timingMode = .easeInEaseOut
            deck.runAction(.repeatForever(.sequence([a, b])), forKey: "sway")
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SCNView {
        let parts = DeckModel.scene()
        let view = SCNView(frame: .zero, options: [SCNView.Option.preferLowPowerDevice.rawValue: true])
        view.scene = parts.scene
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 30
        view.autoenablesDefaultLighting = false
        view.rendersContinuously = false
        view.isPlaying = true
        context.coordinator.material = parts.screen
        context.coordinator.steam = parts.steam
        context.coordinator.deck = parts.deck
        context.coordinator.startSway()
        view.addGestureRecognizer(NSPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:))))
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        let c = context.coordinator
        if c.lastID != screenID {
            c.lastID = screenID
            let renderer = ImageRenderer(content: screen.frame(width: 640, height: 400))
            renderer.scale = 2
            c.material?.diffuse.contents = renderer.nsImage
        }
        if pulseSteam != c.pulsing, let steam = c.steam {
            c.pulsing = pulseSteam
            steam.removeAction(forKey: "pulse")
            if pulseSteam, !Motion.reduced {
                let up = SCNAction.scale(to: 1.14, duration: 0.6)
                let down = SCNAction.scale(to: 1, duration: 0.6)
                steam.runAction(.repeatForever(.sequence([up, down])), forKey: "pulse")
            } else {
                steam.scale = SCNVector3(1, 1, 1)
            }
        }
    }
}
