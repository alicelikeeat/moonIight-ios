import Foundation

/// Minimal static USDZ writer: stored ZIP entries aligned to 64 bytes.
/// Only used for the generated depth surface; never converts rigged assets.
enum DepthUSDZWriter {
    static func write(mesh: DepthMesh, png: Data, to url: URL) throws {
        try mesh.validate()
        let points = mesh.positions.map { "(\($0.x), \($0.y), \($0.z))" }.joined(separator: ", ")
        let coordinates = mesh.textureCoordinates.map { "(\($0.x), \($0.y))" }.joined(separator: ", ")
        let faces = mesh.indices.map(String.init).joined(separator: ", ")
        let counts = Array(repeating: "3", count: mesh.triangleCount).joined(separator: ", ")
        let usd = """
        #usda 1.0
        (
            defaultPrim = "DepthSurface"
            metersPerUnit = 1
            upAxis = "Y"
        )
        def Xform "DepthSurface" {
            custom string modelType = "monocularDepthSurface_missingBack"
            def Mesh "Geometry" (
                prepend apiSchemas = ["MaterialBindingAPI"]
            ) {
                int[] faceVertexCounts = [\(counts)]
                int[] faceVertexIndices = [\(faces)]
                point3f[] points = [\(points)]
                texCoord2f[] primvars:st = [\(coordinates)] (
                    interpolation = "vertex"
                )
                uniform token subdivisionScheme = "none"
                bool doubleSided = true
                rel material:binding = </DepthSurface/Material>
            }
            def Material "Material" {
                token outputs:surface.connect = </DepthSurface/Material/Surface.outputs:surface>
                def Shader "Surface" {
                    uniform token info:id = "UsdPreviewSurface"
                    color3f inputs:diffuseColor.connect = </DepthSurface/Material/Texture.outputs:rgb>
                    float inputs:roughness = 0.8
                    token outputs:surface
                }
                def Shader "UV" {
                    uniform token info:id = "UsdPrimvarReader_float2"
                    token inputs:varname = "st"
                    float2 outputs:result
                }
                def Shader "Texture" {
                    uniform token info:id = "UsdUVTexture"
                    asset inputs:file = @texture.png@
                    token inputs:sourceColorSpace = "sRGB"
                    float2 inputs:st.connect = </DepthSurface/Material/UV.outputs:result>
                    float3 outputs:rgb
                }
            }
        }
        """
        try archive(entries: [("model.usda", Data(usd.utf8)), ("texture.png", png)]).write(to: url, options: .atomic)
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (0xEDB88320 & (0 &- (crc & 1))) }
        }
        return ~crc
    }

    private static func archive(entries: [(String, Data)]) -> Data {
        var result = Data(), central = Data()
        for (name, contents) in entries {
            let filename = Data(name.utf8), offset = UInt32(result.count), checksum = crc32(contents)
            // Extra field includes a four-byte header, followed by padding.
            let padding = (64 - ((result.count + 30 + filename.count + 4) % 64)) % 64
            let extraLength = UInt16(padding + 4)
            result.le(UInt32(0x04034B50)); result.le(UInt16(20)); result.le(UInt16(0))
            result.le(UInt16(0)); result.le(UInt16(0)); result.le(UInt16(0))
            result.le(checksum); result.le(UInt32(contents.count)); result.le(UInt32(contents.count))
            result.le(UInt16(filename.count)); result.le(extraLength); result.append(filename)
            result.le(UInt16(0x1986)); result.le(UInt16(padding)); result.append(Data(repeating: 0, count: padding))
            result.append(contents)
            central.le(UInt32(0x02014B50)); central.le(UInt16(20)); central.le(UInt16(20))
            for _ in 0..<4 { central.le(UInt16(0)) }
            central.le(checksum); central.le(UInt32(contents.count)); central.le(UInt32(contents.count))
            central.le(UInt16(filename.count))
            for _ in 0..<4 { central.le(UInt16(0)) }
            central.le(UInt32(0)); central.le(offset); central.append(filename)
        }
        let start = UInt32(result.count)
        result.append(central)
        result.le(UInt32(0x06054B50)); result.le(UInt16(0)); result.le(UInt16(0))
        result.le(UInt16(entries.count)); result.le(UInt16(entries.count))
        result.le(UInt32(central.count)); result.le(start); result.le(UInt16(0))
        return result
    }
}

private extension Data {
    mutating func le<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
