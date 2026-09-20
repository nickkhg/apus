import CGLES
import Glibc
import Render

/// Draws display lists with the GPU, through OpenGL ES 2.
///
/// The display list is the same one that SoftwareRenderer takes, so nothing
/// above the renderer changes. Each item becomes one quad:
///
/// | Item | How |
/// |---|---|
/// | `fill` | a quad in the colour |
/// | `bitmap` | a quad with the pixels in a texture |
/// | `path` | a quad with the coverage of the path in a texture |
/// | `pushClip`, `popClip` | glScissor |
///
/// Colours are premultiplied, so the blend is `src + dst × (1 − αsrc)`, the
/// same rule that the CPU renderer follows.
///
/// A path becomes a texture because the GPU has no rule for filling an
/// outline. The coverage comes from the rasterizer that the CPU renderer
/// uses, so the edges are the same. The masks are kept, and a shape that
/// does not change is rasterized one time. See docs/ui.md.
final class GLRenderer {
    private var solid: Program
    private var textured: Program
    private var vertexBuffer: GLuint = 0
    private var textures = TextureCache()

    /// A compiled program and where its inputs are.
    private struct Program {
        let id: GLuint
        let position: GLint
        let texturePoint: GLint
        let viewport: GLint
        let color: GLint
        let image: GLint
        let sampleAlphaOnly: GLint
        let forceOpaque: GLint
    }

    init() throws(GLFailure) {
        solid = try GLRenderer.program(fragment: GLRenderer.solidFragment)
        textured = try GLRenderer.program(fragment: GLRenderer.texturedFragment)
        glGenBuffers(1, &vertexBuffer)
        glDisable(GLenum(GL_DEPTH_TEST))
        glDisable(GLenum(GL_CULL_FACE))
        glEnable(GLenum(GL_BLEND))
        // Premultiplied source-over, as in SoftwareRenderer.blend.
        glBlendFunc(GLenum(GL_ONE), GLenum(GL_ONE_MINUS_SRC_ALPHA))
        glPixelStorei(GLenum(GL_UNPACK_ALIGNMENT), 1)
    }

    /// Draws a list into the framebuffer that is bound, `width` × `height`.
    func render(_ list: DisplayList, width: Int, height: Int) {
        glViewport(0, 0, GLsizei(width), GLsizei(height))
        glDisable(GLenum(GL_SCISSOR_TEST))
        glClearColor(0, 0, 0, 1)
        glClear(GLbitfield(GL_COLOR_BUFFER_BIT))

        let whole = Rect(x: 0, y: 0, width: width, height: height)
        var clip = whole
        var stack: [Rect] = []
        textures.startFrame()

        for item in list {
            switch item {
            case .fill(let rect, let color):
                fill(rect, color: color, clip: clip, screen: (width, height))
            case .bitmap(let bitmap, let x, let y):
                draw(bitmap, x: x, y: y, clip: clip, screen: (width, height))
            case .path(let path, let color):
                fill(path, color: color, clip: clip, screen: (width, height))
            case .pushClip(let rect):
                stack.append(clip)
                clip = intersection(clip, rect)
            case .popClip:
                clip = stack.popLast() ?? whole
            }
        }
        textures.endFrame()
        glDisable(GLenum(GL_SCISSOR_TEST))
    }

    // MARK: - Items

    private func fill(_ rect: Rect, color: UInt32, clip: Rect, screen: (width: Int, height: Int)) {
        let box = intersection(rect, clip)
        guard box.width > 0, box.height > 0, color >> 24 != 0 else { return }
        use(solid, screen: screen)
        set(color: color, on: solid)
        scissor(clip, screen: screen)
        drawQuad(box, of: solid)
    }

    private func draw(_ bitmap: Bitmap, x: Int, y: Int, clip: Rect,
                      screen: (width: Int, height: Int)) {
        let target = Rect(x: x, y: y, width: bitmap.width, height: bitmap.height)
        guard intersection(target, clip).width > 0, intersection(target, clip).height > 0 else {
            return
        }
        let name = textures.texture(for: bitmap)
        use(textured, screen: screen)
        glUniform1f(textured.sampleAlphaOnly, 0)
        glUniform1f(textured.forceOpaque, bitmap.isOpaque ? 1 : 0)
        set(color: 0xFFFFFFFF, on: textured)
        bind(name, on: textured)
        scissor(clip, screen: screen)
        drawQuad(target, of: textured)
    }

    private func fill(_ path: Path, color: UInt32, clip: Rect,
                      screen: (width: Int, height: Int)) {
        let box = intersection(clip, Rect(x: 0, y: 0, width: screen.width, height: screen.height))
        guard box.width > 0, box.height > 0, color >> 24 != 0 else { return }
        guard let mask = textures.mask(for: path, clippedTo: box) else { return }

        use(textured, screen: screen)
        // The mask holds coverage only, so the colour comes from the uniform.
        glUniform1f(textured.sampleAlphaOnly, 1)
        glUniform1f(textured.forceOpaque, 0)
        set(color: color, on: textured)
        bind(mask.texture, on: textured)
        scissor(clip, screen: screen)
        drawQuad(mask.rect, of: textured)
    }

    // MARK: - Drawing

    private func use(_ program: Program, screen: (width: Int, height: Int)) {
        glUseProgram(program.id)
        glUniform2f(program.viewport, GLfloat(screen.width), GLfloat(screen.height))
    }

    private func set(color: UInt32, on program: Program) {
        glUniform4f(program.color,
                    GLfloat((color >> 16) & 0xFF) / 255,
                    GLfloat((color >> 8) & 0xFF) / 255,
                    GLfloat(color & 0xFF) / 255,
                    GLfloat((color >> 24) & 0xFF) / 255)
    }

    private func bind(_ texture: GLuint, on program: Program) {
        glActiveTexture(GLenum(GL_TEXTURE0))
        glBindTexture(GLenum(GL_TEXTURE_2D), texture)
        glUniform1i(program.image, 0)
    }

    /// The scissor is in GL coordinates, which count from the bottom.
    private func scissor(_ clip: Rect, screen: (width: Int, height: Int)) {
        let box = intersection(clip, Rect(x: 0, y: 0, width: screen.width, height: screen.height))
        glEnable(GLenum(GL_SCISSOR_TEST))
        glScissor(GLint(box.x), GLint(screen.height - box.y - box.height),
                  GLsizei(max(0, box.width)), GLsizei(max(0, box.height)))
    }

    private func drawQuad(_ rect: Rect, of program: Program) {
        let x0 = GLfloat(rect.x), y0 = GLfloat(rect.y)
        let x1 = GLfloat(rect.x + rect.width), y1 = GLfloat(rect.y + rect.height)
        // Two triangles: position (x, y) then the point in the texture (u, v).
        let vertices: [GLfloat] = [
            x0, y0, 0, 0,
            x1, y0, 1, 0,
            x0, y1, 0, 1,
            x1, y1, 1, 1,
        ]
        glBindBuffer(GLenum(GL_ARRAY_BUFFER), vertexBuffer)
        vertices.withUnsafeBytes { bytes in
            glBufferData(GLenum(GL_ARRAY_BUFFER), bytes.count, bytes.baseAddress,
                         GLenum(GL_STREAM_DRAW))
        }
        let stride = GLsizei(MemoryLayout<GLfloat>.size * 4)
        glEnableVertexAttribArray(GLuint(program.position))
        glVertexAttribPointer(GLuint(program.position), 2, GLenum(GL_FLOAT), GLboolean(GL_FALSE),
                              stride, nil)
        glEnableVertexAttribArray(GLuint(program.texturePoint))
        glVertexAttribPointer(GLuint(program.texturePoint), 2, GLenum(GL_FLOAT), GLboolean(GL_FALSE),
                              stride, UnsafeRawPointer(bitPattern: MemoryLayout<GLfloat>.size * 2))
        glDrawArrays(GLenum(GL_TRIANGLE_STRIP), 0, 4)
    }

    private func intersection(_ a: Rect, _ b: Rect) -> Rect {
        let x0 = max(a.x, b.x), y0 = max(a.y, b.y)
        let x1 = min(a.x + a.width, b.x + b.width)
        let y1 = min(a.y + a.height, b.y + b.height)
        return Rect(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0))
    }

    // MARK: - Programs

    /// Screen pixels in, clip coordinates out. The screen counts rows from
    /// the top and GL counts them from the bottom, so y is turned over.
    private static let vertexShader = """
        attribute vec2 position;
        attribute vec2 texturePoint;
        uniform vec2 viewport;
        varying vec2 point;
        void main() {
            point = texturePoint;
            vec2 unit = position / viewport;
            gl_Position = vec4(unit.x * 2.0 - 1.0, 1.0 - unit.y * 2.0, 0.0, 1.0);
        }
        """

    private static let solidFragment = """
        precision mediump float;
        uniform vec4 color;
        void main() { gl_FragColor = color; }
        """

    /// The pixels of a Bitmap are 0xAARRGGBB in a 32-bit word, so in memory
    /// they are blue, green, red, alpha. GL reads them as red, green, blue,
    /// alpha, and `.bgra` puts them back in order.
    ///
    /// With `sampleAlphaOnly`, the texture holds coverage and the colour
    /// comes from the uniform. With `forceOpaque`, the alpha of the texture
    /// is ignored, because the bitmap said it has none.
    private static let texturedFragment = """
        precision mediump float;
        uniform sampler2D image;
        uniform vec4 color;
        uniform float sampleAlphaOnly;
        uniform float forceOpaque;
        varying vec2 point;
        void main() {
            vec4 texel = texture2D(image, point);
            vec4 pixel = vec4(texel.b, texel.g, texel.r, texel.a);
            pixel.a = mix(pixel.a, 1.0, forceOpaque);
            vec4 covered = color * texel.a;
            gl_FragColor = mix(pixel * color, covered, sampleAlphaOnly);
        }
        """

    private static func program(fragment source: String) throws(GLFailure) -> Program {
        let vertex = try compile(GLenum(GL_VERTEX_SHADER), vertexShader)
        let fragmentShader = try compile(GLenum(GL_FRAGMENT_SHADER), source)
        let id = glCreateProgram()
        glAttachShader(id, vertex)
        glAttachShader(id, fragmentShader)
        glLinkProgram(id)
        var linked: GLint = 0
        glGetProgramiv(id, GLenum(GL_LINK_STATUS), &linked)
        guard linked == GL_TRUE else {
            throw .program(message(of: id, get: glGetProgramInfoLog, length: glGetProgramiv))
        }
        glDeleteShader(vertex)
        glDeleteShader(fragmentShader)
        return Program(
            id: id,
            position: glGetAttribLocation(id, "position"),
            texturePoint: glGetAttribLocation(id, "texturePoint"),
            viewport: glGetUniformLocation(id, "viewport"),
            color: glGetUniformLocation(id, "color"),
            image: glGetUniformLocation(id, "image"),
            sampleAlphaOnly: glGetUniformLocation(id, "sampleAlphaOnly"),
            forceOpaque: glGetUniformLocation(id, "forceOpaque"))
    }

    private static func compile(_ kind: GLenum, _ source: String) throws(GLFailure) -> GLuint {
        let shader = glCreateShader(kind)
        var pointer = UnsafePointer<CChar>(strdup(source))
        defer { free(UnsafeMutableRawPointer(mutating: pointer)) }
        glShaderSource(shader, 1, &pointer, nil)
        glCompileShader(shader)
        var compiled: GLint = 0
        glGetShaderiv(shader, GLenum(GL_COMPILE_STATUS), &compiled)
        guard compiled == GL_TRUE else {
            throw .shader(message(of: shader, get: glGetShaderInfoLog, length: glGetShaderiv))
        }
        return shader
    }

    private static func message(
        of object: GLuint,
        get: (GLuint, GLsizei, UnsafeMutablePointer<GLsizei>?, UnsafeMutablePointer<GLchar>?) -> Void,
        length: (GLuint, GLenum, UnsafeMutablePointer<GLint>?) -> Void
    ) -> String {
        var size: GLint = 0
        length(object, GLenum(GL_INFO_LOG_LENGTH), &size)
        guard size > 1 else { return "no message" }
        var buffer = [GLchar](repeating: 0, count: Int(size))
        get(object, GLsizei(size), nil, &buffer)
        return String(cString: buffer)
    }
}

enum GLFailure: Error, CustomStringConvertible {
    case shader(String)
    case program(String)
    case display(String)

    var description: String {
        switch self {
        case .shader(let message): "cannot compile a shader: \(message)"
        case .program(let message): "cannot link a program: \(message)"
        case .display(let message): "cannot start GPU rendering: \(message)"
        }
    }
}
