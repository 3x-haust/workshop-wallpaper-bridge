import AppKit
import OpenGL.GL3

/// Executes bounded, local full-quad shader passes in an offscreen GL context.
/// The original shader math, uniforms, combo defaults and buffer bindings stay
/// in the package. This is not a replacement for the whole scene renderer.
final class SceneShaderRenderer {
    private let context: NSOpenGLContext
    private var programs: [String: GLuint] = [:]
    private let maximumPixels = 2_097_152

    init() throws {
        let attributes: [NSOpenGLPixelFormatAttribute] = [UInt32(NSOpenGLPFAOpenGLProfile), UInt32(NSOpenGLProfileVersion4_1Core), 0]
        guard let format = NSOpenGLPixelFormat(attributes: attributes), let context = NSOpenGLContext(format: format, share: nil) else {
            throw SceneShaderEffect.Failure.unsupported("OpenGL context unavailable")
        }
        self.context = context
    }

    func render(_ image: CGImage, effects: [SceneShaderEffect], time: Double, values: [String: [String: Any]], currentArtwork: CGImage? = nil, previousArtwork: CGImage? = nil) throws -> CGImage {
        guard image.width > 0, image.height > 0, image.width * image.height <= maximumPixels, time.isFinite else {
            throw SceneShaderEffect.Failure.unsupported("effect surface limit")
        }
        let old = NSOpenGLContext.current
        context.makeCurrentContext()
        defer { if let old { old.makeCurrentContext() } else { NSOpenGLContext.clearCurrentContext() } }
        var textures: [GLuint] = []
        var allocatedPixels = 0
        var framebuffer: GLuint = 0, vao: GLuint = 0, vbo: GLuint = 0
        glGenFramebuffers(1, &framebuffer); glBindFramebuffer(GLenum(GL_FRAMEBUFFER), framebuffer)
        glGenVertexArrays(1, &vao); glBindVertexArray(vao)
        glGenBuffers(1, &vbo); glBindBuffer(GLenum(GL_ARRAY_BUFFER), vbo)
        let vertices: [GLfloat] = [-1,-1,0,0,0, 1,-1,0,1,0, -1,1,0,0,1, 1,1,0,1,1]
        vertices.withUnsafeBytes { glBufferData(GLenum(GL_ARRAY_BUFFER), $0.count, $0.baseAddress, GLenum(GL_STATIC_DRAW)) }
        glVertexAttribPointer(0, 3, GLenum(GL_FLOAT), GLboolean(GL_FALSE), 20, nil); glEnableVertexAttribArray(0)
        glVertexAttribPointer(1, 2, GLenum(GL_FLOAT), GLboolean(GL_FALSE), 20, UnsafeRawPointer(bitPattern: 12)); glEnableVertexAttribArray(1)
        glViewport(0, 0, GLsizei(image.width), GLsizei(image.height))
        glDisable(GLenum(GL_BLEND)); glDisable(GLenum(GL_DEPTH_TEST)); glDisable(GLenum(GL_CULL_FACE))
        defer {
            glDeleteTextures(GLsizei(textures.count), &textures)
            glDeleteBuffers(1, &vbo); glDeleteVertexArrays(1, &vao); glDeleteFramebuffers(1, &framebuffer)
        }
        func allocate(_ input: CGImage? = nil, repeating: Bool = false) throws -> GLuint {
            allocatedPixels += input.map { $0.width * $0.height } ?? image.width * image.height
            guard allocatedPixels <= 16_777_216 else { throw SceneShaderEffect.Failure.unsupported("effect texture memory limit") }
            var previousBinding: GLint = 0
            glGetIntegerv(GLenum(GL_TEXTURE_BINDING_2D), &previousBinding)
            defer { glBindTexture(GLenum(GL_TEXTURE_2D), GLuint(previousBinding)) }
            var id: GLuint = 0; glGenTextures(1, &id); textures.append(id)
            glBindTexture(GLenum(GL_TEXTURE_2D), id)
            glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MIN_FILTER), GL_LINEAR)
            glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MAG_FILTER), GL_LINEAR)
            glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_S), repeating ? GL_REPEAT : GL_CLAMP_TO_EDGE)
            glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_T), repeating ? GL_REPEAT : GL_CLAMP_TO_EDGE)
            if let input {
                guard input.width * input.height <= 4_194_304 else { throw SceneShaderEffect.Failure.unsupported("sampler texture limit") }
                var bytes = [UInt8](repeating: 0, count: input.width * input.height * 4)
                try bytes.withUnsafeMutableBytes { storage in
                    guard let drawing = CGContext(data: storage.baseAddress, width: input.width, height: input.height, bitsPerComponent: 8, bytesPerRow: input.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                        throw SceneShaderEffect.Failure.unsupported("texture allocation failed")
                    }
                    drawing.draw(input, in: CGRect(x: 0, y: 0, width: input.width, height: input.height))
                    let pixels = storage.bindMemory(to: UInt8.self)
                    for offset in stride(from: 0, to: pixels.count, by: 4) {
                        let alpha = Int(pixels[offset + 3])
                        if alpha > 0 && alpha < 255 {
                            for component in 0..<3 { pixels[offset + component] = UInt8(min(255, Int(pixels[offset + component]) * 255 / alpha)) }
                        }
                    }
                    glTexImage2D(GLenum(GL_TEXTURE_2D), 0, GL_RGBA8, GLsizei(input.width), GLsizei(input.height), 0, GLenum(GL_RGBA), GLenum(GL_UNSIGNED_BYTE), storage.baseAddress)
                }
            } else {
                glTexImage2D(GLenum(GL_TEXTURE_2D), 0, GL_RGBA8, GLsizei(image.width), GLsizei(image.height), 0, GLenum(GL_RGBA), GLenum(GL_UNSIGNED_BYTE), nil)
            }
            return id
        }
        var current = try allocate(image)
        for effect in effects where values[effect.id]?["visible"] as? Bool ?? effect.visible {
            let previous = current
            var named: [String: GLuint] = ["previous": previous]
            for (index, pass) in effect.passes.enumerated() {
                let program = try program(pass, key: effect.id + "/\(index)")
                glUseProgram(program)
                let output = try allocate()
                glFramebufferTexture2D(GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0), GLenum(GL_TEXTURE_2D), output, 0)
                guard glCheckFramebufferStatus(GLenum(GL_FRAMEBUFFER)) == GLenum(GL_FRAMEBUFFER_COMPLETE) else {
                    throw SceneShaderEffect.Failure.unsupported("incomplete effect framebuffer")
                }
                glClearColor(0, 0, 0, 0)
                glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
                for slot in 0..<8 {
                    let location = glGetUniformLocation(program, "g_Texture\(slot)")
                    guard location >= 0 else { continue }
                    let sampler: GLuint
                    let texture: CGImage?
                    if let name = pass.systemTextures[slot] {
                        texture = (name == "$mediaPreviousThumbnail" ? previousArtwork : currentArtwork) ?? pass.textures[slot]
                    } else { texture = pass.textures[slot] }
                    if let binding = pass.bindings[slot] {
                        guard let target = named[binding] else { throw SceneShaderEffect.Failure.unsupported("unresolved named framebuffer") }
                        sampler = target
                    } else if let texture { sampler = try allocate(texture, repeating: pass.systemTextures[slot] == nil) }
                    else { sampler = current }
                    glActiveTexture(GLenum(GL_TEXTURE0 + Int32(slot)))
                    glBindTexture(GLenum(GL_TEXTURE_2D), sampler); glUniform1i(location, GLint(slot))
                    let size = texture.map { ($0.width, $0.height) } ?? (image.width, image.height)
                    glUniform4f(glGetUniformLocation(program, "g_Texture\(slot)Resolution"), Float(size.0), Float(size.1), Float(size.0), Float(size.1))
                }
                glUniform4f(glGetUniformLocation(program, "g_Texture0Resolution"), Float(image.width), Float(image.height), Float(image.width), Float(image.height))
                glUniform2f(glGetUniformLocation(program, "g_TexelSize"), 1 / Float(image.width), 1 / Float(image.height))
                glUniform1f(glGetUniformLocation(program, "g_Time"), Float(time))
                let identity: [GLfloat] = [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1]
                glUniformMatrix4fv(glGetUniformLocation(program, "g_ModelViewProjectionMatrix"), 1, GLboolean(GL_FALSE), identity)
                for uniform in pass.uniforms where uniform.type != "sampler2D" {
                    let bound = pass.uniformKeys[uniform.material].flatMap { values[$0]?["value"] }
                    let raw = SceneMediaOverlayPlan.unwrap(bound ?? pass.constants[uniform.material] ?? uniform.value)
                    let vector: [Float]
                    if let value = raw as? Double { vector = [Float(value)] }
                    else if let value = raw as? String { vector = value.split(whereSeparator: \.isWhitespace).compactMap { Float($0) } }
                    else if let value = raw as? [Double] { vector = value.map(Float.init) }
                    else { continue }
                    guard vector.allSatisfy({ $0.isFinite && abs($0) <= 1e7 }) else { continue }
                    let location = glGetUniformLocation(program, uniform.name)
                    switch (uniform.type, vector.count) {
                    case ("float", 1): glUniform1f(location, vector[0])
                    case ("int", 1): glUniform1i(location, GLint(vector[0]))
                    case ("vec2", 2): glUniform2f(location, vector[0], vector[1])
                    case ("vec3", 3): glUniform3f(location, vector[0], vector[1], vector[2])
                    case ("vec4", 4): glUniform4f(location, vector[0], vector[1], vector[2], vector[3])
                    default: throw SceneShaderEffect.Failure.unsupported("unsupported shader uniform type")
                    }
                }
                glDrawArrays(GLenum(GL_TRIANGLE_STRIP), 0, 4)
                if let target = pass.target { named[target] = output } else { current = output }
            }
        }
        glFramebufferTexture2D(GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0), GLenum(GL_TEXTURE_2D), current, 0)
        var output = Data(count: image.width * image.height * 4)
        output.withUnsafeMutableBytes { glReadPixels(0, 0, GLsizei(image.width), GLsizei(image.height), GLenum(GL_RGBA), GLenum(GL_UNSIGNED_BYTE), $0.baseAddress) }
        guard glGetError() == GLenum(GL_NO_ERROR), let provider = CGDataProvider(data: output as CFData),
              let result = CGImage(width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: image.width * 4,
                                   space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
            throw SceneShaderEffect.Failure.unsupported("effect readback failed")
        }
        return result
    }

    private func program(_ pass: SceneShaderEffect.Pass, key: String) throws -> GLuint {
        if let program = programs[key] { return program }
        guard programs.count < 32 else { throw SceneShaderEffect.Failure.unsupported("shader program limit") }
        let prefix = """
        #version 410 core
        #define mul(x,y) ((y)*(x))
        #define lerp mix
        #define frac fract
        #define CAST2(x) vec2(x)
        #define CAST3(x) vec3(x)
        #define CAST4(x) vec4(x)
        #define CAST3X3(x) mat3(x)
        #define saturate(x) clamp(x,0.0,1.0)
        #define texSample2D texture
        #define texSample2DLod textureLod
        #define atan2 atan
        #define ddx dFdx
        #define ddy(x) dFdy(-(x))
        #define GLSL 1
        """ + "\n" + pass.resolvedCombos.sorted(by: { $0.key < $1.key }).map { "#define \($0.key) \($0.value)\n" }.joined()
        func compile(_ source: String, _ type: GLenum) throws -> GLuint {
            let stage = type == GLenum(GL_VERTEX_SHADER) ? "#define attribute in\n#define varying out\n" : "#define varying in\nout vec4 sceneOutput;\n#define gl_FragColor sceneOutput\n"
            let text = prefix + stage + Self.explicitVectorProducts(source)
            let shader = glCreateShader(type)
            text.withCString { pointer in
                var p: UnsafePointer<GLchar>? = pointer
                glShaderSource(shader, 1, &p, nil)
            }
            glCompileShader(shader)
            var status: GLint = 0; glGetShaderiv(shader, GLenum(GL_COMPILE_STATUS), &status)
            guard status != 0 else {
                var log = [GLchar](repeating: 0, count: 2048); glGetShaderInfoLog(shader, 2048, nil, &log)
                glDeleteShader(shader)
                throw SceneShaderEffect.Failure.unsupported(key + " compile failed: " + String(cString: log))
            }
            return shader
        }
        let vertex = try compile(pass.vertex, GLenum(GL_VERTEX_SHADER)); defer { glDeleteShader(vertex) }
        let fragment = try compile(pass.fragment, GLenum(GL_FRAGMENT_SHADER)); defer { glDeleteShader(fragment) }
        let program = glCreateProgram(); glAttachShader(program, vertex); glAttachShader(program, fragment)
        glBindAttribLocation(program, 0, "a_Position"); glBindAttribLocation(program, 1, "a_TexCoord")
        glLinkProgram(program)
        var status: GLint = 0; glGetProgramiv(program, GLenum(GL_LINK_STATUS), &status)
        guard status != 0 else { glDeleteProgram(program); throw SceneShaderEffect.Failure.unsupported("shader link failed") }
        programs[key] = program
        return program
    }

    /// The source dialect allows a larger RHS vector in a vec2 product.
    /// Make that truncation explicit only for simple, typed vec2 assignments.
    static func explicitVectorProducts(_ source: String) -> String {
        let declarations = try! NSRegularExpression(pattern: #"\bvec[34]\s+(\w+)\s*;"#)
        let names = declarations.matches(in: source, range: NSRange(source.startIndex..., in: source)).map {
            String(source[Range($0.range(at: 1), in: source)!])
        }
        return source.components(separatedBy: .newlines).map { line in
            guard line.range(of: #"^\s*vec2\s+\w+\s*="#, options: .regularExpression) != nil else { return line }
            var value = line
            for name in names {
                value = value.replacingOccurrences(of: #"(\*\s*)\b"# + NSRegularExpression.escapedPattern(for: name) + #"\b(?!\s*\.)"#, with: "$1" + name + ".xy", options: .regularExpression)
            }
            return value
        }.joined(separator: "\n")
    }
}

/// A request owns a read-only snapshot of JSON values and retained CGImages.
/// The actor serializes all GL access; no CALayer or NSView crosses this boundary.
struct SceneShaderRequest: @unchecked Sendable {
    let image: CGImage
    let effects: [SceneShaderEffect]
    let time: Double
    let values: [String: [String: Any]]
    let currentArtwork: CGImage?
    let previousArtwork: CGImage?
}
struct SceneShaderResult: @unchecked Sendable { let image: CGImage }
actor SceneShaderExecutor {
    private var renderer: SceneShaderRenderer?
    func render(_ request: SceneShaderRequest) throws -> SceneShaderResult {
        if renderer == nil { renderer = try SceneShaderRenderer() }
        let image = try renderer!.render(request.image, effects: request.effects, time: request.time,
            values: request.values, currentArtwork: request.currentArtwork, previousArtwork: request.previousArtwork)
        return SceneShaderResult(image: image)
    }
}
