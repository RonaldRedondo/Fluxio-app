import AppKit
import ModelIO
import SceneKit
import SceneKit.ModelIO

/// Modelos 3D con ModelIO de macOS: OBJ ↔ STL ↔ PLY ↔ USD, y una vista previa en PNG.
/// (USDZ y Alembic se pueden abrir, pero no guardar.)
struct ModelConverter: Converter {
    let id = "model.convert"
    let mode = WheelMode.convert

    private static let inputs = ["obj", "stl", "ply", "usd", "usda", "usdc", "usdz", "abc"]
    private static let outputs: [(ext: String, title: String)] = [("obj", "OBJ"), ("stl", "STL"), ("ply", "PLY"),
                                                                    ("usdc", "USD"), ("usda", "USDA")]

    func options(for file: FileInfo) -> [WheelOption] {
        let ext = file.url.pathExtension.lowercased()
        guard Self.inputs.contains(ext) else { return [] }
        var result = Self.outputs.filter { $0.ext != ext && !(ext == "usd" && $0.ext == "usdc") }.map {
            WheelOption(id: "\(id).\($0.ext)", providerID: id, title: $0.title, symbol: "cube",
                        accessibilityLabel: "Convertir el modelo a \($0.title)")
        }
        result.append(WheelOption(id: "\(id).png", providerID: id, title: "Vista PNG", symbol: "camera.viewfinder",
                                  accessibilityLabel: "Crear una imagen de vista previa del modelo"))
        return result
    }

    func run(_ option: WheelOption, on file: FileInfo, context: JobContext) throws -> [URL] {
        let target = action(of: option)
        let asset = MDLAsset(url: file.url)
        guard asset.count > 0 else { throw ConversionError.unreadable(file.url.lastPathComponent) }
        context.report(0.3)

        if target == "png" { return [try preview(asset, for: file, context: context)] }

        guard MDLAsset.canExportFileExtension(target) else { throw ConversionError.unsupported }
        // Se exporta en una carpeta temporal: OBJ puede crear además su archivo de materiales (.mtl).
        let work = context.temporaryURL(ext: "modelo")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let temp = work.appendingPathComponent(file.url.deletingPathExtension().lastPathComponent)
            .appendingPathExtension(target)
        do {
            try asset.export(to: temp)
        } catch {
            throw ConversionError.writeFailed(target.uppercased())
        }
        let main = try context.finalize(temp: temp, for: file.url, ext: target)
        var outputs = [main]
        // Materiales de OBJ: se guardan junto al modelo con el mismo nombre.
        for extra in (try? FileManager.default.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)) ?? []
        where extra.pathExtension.lowercased() == "mtl" {
            let destination = main.deletingPathExtension().appendingPathExtension("mtl")
            try? FileManager.default.removeItem(at: destination)
            if (try? FileManager.default.moveItem(at: extra, to: destination)) != nil { outputs.append(destination) }
        }
        return outputs
    }

    /// Imagen de 1200 × 900 del modelo, con luz y cámara automáticas, sobre fondo transparente.
    private func preview(_ asset: MDLAsset, for file: FileInfo, context: JobContext) throws -> URL {
        let image: CGImage? = {
            let work = {
                let scene = SCNScene(mdlAsset: asset)
                let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
                renderer.scene = scene
                renderer.autoenablesDefaultLighting = true
                scene.background.contents = NSColor.clear
                // Los modelos sin color propio (STL, OBJ sin materiales) se ven en gris neutro, no en blanco.
                scene.rootNode.enumerateHierarchy { node, _ in
                    for material in node.geometry?.materials ?? [] {
                        let diffuse = material.diffuse.contents
                        // Sin color, o blanco puro (lo que ponen por defecto STL y OBJ sin materiales).
                        var isPlainWhite = diffuse == nil
                        if let color = diffuse as? NSColor, let rgb = color.usingColorSpace(.sRGB) {
                            isPlainWhite = rgb.redComponent > 0.97 && rgb.greenComponent > 0.97 && rgb.blueComponent > 0.97
                        } else if let any = diffuse, CFGetTypeID(any as CFTypeRef) == CGColor.typeID,
                                  let rgb = NSColor(cgColor: any as! CGColor)?.usingColorSpace(.sRGB) {
                            isPlainWhite = rgb.redComponent > 0.97 && rgb.greenComponent > 0.97 && rgb.blueComponent > 0.97
                        }
                        if isPlainWhite {
                            material.diffuse.contents = NSColor(white: 0.68, alpha: 1)
                        }
                        material.lightingModel = .physicallyBased
                        material.roughness.contents = 0.55
                    }
                }
                // Cámara que encuadra todo el modelo.
                let (minB, maxB) = scene.rootNode.boundingBox
                let center = SCNVector3((minB.x + maxB.x) / 2, (minB.y + maxB.y) / 2, (minB.z + maxB.z) / 2)
                let size = max(maxB.x - minB.x, maxB.y - minB.y, maxB.z - minB.z)
                let camera = SCNNode()
                camera.camera = SCNCamera()
                camera.camera?.zFar = Double(size) * 20 + 100
                camera.camera?.fieldOfView = 35
                // Cámara en diagonal, a la distancia justa para que el modelo llene el encuadre.
                camera.position = SCNVector3(center.x + size * 0.75, center.y + size * 0.65, center.z + size * 1.15)
                camera.look(at: center)
                scene.rootNode.addChildNode(camera)
                renderer.pointOfView = camera
                let snapshot = renderer.snapshot(atTime: 0, with: CGSize(width: 1200, height: 900), antialiasingMode: .multisampling4X)
                return snapshot.cgImage(forProposedRect: nil, context: nil, hints: nil)
            }
            return Thread.isMainThread ? work() : DispatchQueue.main.sync(execute: work)
        }()
        guard let image else { throw ConversionError.writeFailed("PNG") }
        let temp = context.temporaryURL(ext: "png")
        defer { try? FileManager.default.removeItem(at: temp) }
        try ImageIOHelpers.write(image, as: .png, metadata: [:], quality: 1, to: temp, context: context)
        return try context.finalize(temp: temp, for: file.url, ext: "png", tag: "vista")
    }
}
