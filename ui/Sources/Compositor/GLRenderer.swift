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
/// | `shadow` | a quad with the soft coverage of the path in a texture |
/// | `gradient` | a quad, with the colour mixed in the shader |
/// | `blur` | the screen copied to a texture, then two passes |
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
    private var gradient: Program
    private var soft: Program
    private var vertexBuffer: GLuint = 0
    private var textures = TextureCache()
    /// Where a blur puts the picture while it works on it.
    private var scratch = Scratch()

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
        /// The second colour of a gradient, and the line that it runs along.
        let colorTo: GLint
        let axisStart: GLint
        let axisEnd: GLint
        /// What a blur pass reads, and where it reads it from.
        let sourceOrigin: GLint
        let sourceSize: GLint
        let step: GLint
        let mask: GLint
        let useMask: GLint
        let fromScreen: GLint
    }

    /// The texture that a blur draws into between its two passes. It is
    /// made once and grows when a larger blur needs it.
    private struct Scratch {
        var framebuffer: GLuint = 0
        var texture: GLuint = 0
        var source: GLuint = 0
        var width: Int = 0
        var height: Int = 0
    }

    init() throws(GLFailure) {
        solid = try GLRenderer.program(fragment: GLRenderer.solidFragment)
        textured = try GLRenderer.program(fragment: GLRenderer.texturedFragment)
        gradient = try GLRenderer.program(fragment: GLRenderer.gradientFragment)
        soft = try GLRenderer.program(fragment: GLRenderer.blurFragment)
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
            case .shadow(let path, let shadow):
                draw(shadow, of: path, clip: clip, screen: (width, height))
            case .gradient(let path, let colours):
                fill(path, gradient: colours, clip: clip, screen: (width, height))
            case .blur(let path, let radius):
                blur(under: path, radius: radius, clip: clip, screen: (width, height))
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

    /// A shadow: the same as a path, with a mask that is soft at its edge.
    ///
    /// The CPU makes the soft coverage and `TextureCache` keeps it, so a
    /// shadow under a cell is made one time and costs one quad after that.
    private func draw(_ shadow: Shadow, of path: Path, clip: Rect,
                      screen: (width: Int, height: Int)) {
        let box = intersection(clip, Rect(x: 0, y: 0, width: screen.width, height: screen.height))
        guard box.width > 0, box.height > 0, shadow.color >> 24 != 0 else { return }
        guard let mask = textures.shadow(for: path, shadow, clippedTo: box) else { return }

        use(textured, screen: screen)
        glUniform1f(textured.sampleAlphaOnly, 1)
        glUniform1f(textured.forceOpaque, 0)
        set(color: shadow.color, on: textured)
        bind(mask.texture, on: textured)
        scissor(clip, screen: screen)
        drawQuad(mask.rect, of: textured)
    }

    /// A gradient: the coverage of the path in a texture, and the colour
    /// worked out for each pixel from where it is on the line.
    private func fill(_ path: Path, gradient colours: Gradient, clip: Rect,
                      screen: (width: Int, height: Int)) {
        let box = intersection(clip, Rect(x: 0, y: 0, width: screen.width, height: screen.height))
        guard box.width > 0, box.height > 0 else { return }
        guard colours.from >> 24 != 0 || colours.to >> 24 != 0 else { return }
        guard let mask = textures.mask(for: path, clippedTo: box) else { return }

        use(gradient, screen: screen)
        set(color: colours.from, on: gradient)
        set(color: colours.to, at: gradient.colorTo)
        glUniform2f(gradient.axisStart, GLfloat(colours.startX), GLfloat(colours.startY))
        glUniform2f(gradient.axisEnd, GLfloat(colours.endX), GLfloat(colours.endY))
        bind(mask.texture, on: gradient)
        scissor(clip, screen: screen)
        drawQuad(mask.rect, of: gradient)
    }

    /// A blur: the picture that the list has made so far, read back and put
    /// down soft inside the path.
    ///
    /// The picture goes to a texture, one pass makes it soft along the rows
    /// into a texture of its own, and the second pass makes it soft down the
    /// columns and puts it on the screen inside the coverage of the path.
    /// Two box passes give the same shape of blur as the CPU renderer.
    private func blur(under path: Path, radius: Double, clip: Rect,
                      screen: (width: Int, height: Int)) {
        let whole = Rect(x: 0, y: 0, width: screen.width, height: screen.height)
        let box = intersection(clip, whole)
        let half = SoftwareRenderer.boxHalfWidth(radius)
        guard box.width > 0, box.height > 0, half > 0 else { return }
        guard let target = SoftwareRenderer.bounds(of: path, clippedTo: box) else { return }
        guard let mask = textures.mask(for: path, clippedTo: box) else { return }

        // The soft pixels at the edge of the shape come from outside it, so
        // the part that is read is larger than the part that is written.
        let spread = 2 * half
        let source = intersection(Rect(x: target.x - spread, y: target.y - spread,
                                       width: target.width + 2 * spread,
                                       height: target.height + 2 * spread), whole)
        guard source.width > 0, source.height > 0 else { return }

        // What the list is drawing into. A screenshot renders into a
        // framebuffer of its own, so this is not always the display.
        var previous: GLint = 0
        glGetIntegerv(GLenum(GL_FRAMEBUFFER_BINDING), &previous)
        guard hold(source, screen: screen, from: GLuint(previous)) else { return }

        let tap = GLfloat(half) / 8

        // Along the rows, into the scratch texture.
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), scratch.framebuffer)
        glViewport(0, 0, GLsizei(source.width), GLsizei(source.height))
        glDisable(GLenum(GL_SCISSOR_TEST))
        glDisable(GLenum(GL_BLEND))
        use(soft, screen: (source.width, source.height))
        glUniform1f(soft.useMask, 0)
        glUniform1f(soft.fromScreen, 0)
        glUniform2f(soft.step, tap / GLfloat(source.width), 0)
        bind(scratch.source, on: soft)
        drawQuad(Rect(x: 0, y: 0, width: source.width, height: source.height), of: soft)

        // Down the columns, onto the screen, inside the path.
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), GLuint(previous))
        glViewport(0, 0, GLsizei(screen.width), GLsizei(screen.height))
        glEnable(GLenum(GL_BLEND))
        use(soft, screen: screen)
        glUniform1f(soft.useMask, 1)
        glUniform1f(soft.fromScreen, 1)
        glUniform2f(soft.step, 0, tap / GLfloat(source.height))
        glUniform2f(soft.sourceOrigin, GLfloat(source.x), GLfloat(source.y))
        glUniform2f(soft.sourceSize, GLfloat(source.width), GLfloat(source.height))
        bind(scratch.texture, on: soft)
        glActiveTexture(GLenum(GL_TEXTURE1))
        glBindTexture(GLenum(GL_TEXTURE_2D), mask.texture)
        glUniform1i(soft.mask, 1)
        glActiveTexture(GLenum(GL_TEXTURE0))
        scissor(clip, screen: screen)
        drawQuad(mask.rect, of: soft)
    }

    /// Copies the picture inside `source` into a texture, and makes the
    /// texture that the first pass writes into the same size. False when
    /// the GPU cannot give the two textures.
    private func hold(_ source: Rect, screen: (width: Int, height: Int),
                      from framebuffer: GLuint) -> Bool {
        if scratch.framebuffer == 0 {
            glGenFramebuffers(1, &scratch.framebuffer)
            scratch.texture = smooth()
            scratch.source = smooth()
        }
        guard scratch.framebuffer != 0, scratch.texture != 0, scratch.source != 0 else {
            return false
        }
        if scratch.width != source.width || scratch.height != source.height {
            glBindTexture(GLenum(GL_TEXTURE_2D), scratch.texture)
            glTexImage2D(GLenum(GL_TEXTURE_2D), 0, GL_RGBA,
                         GLsizei(source.width), GLsizei(source.height), 0,
                         GLenum(GL_RGBA), GLenum(GL_UNSIGNED_BYTE), nil)
            // The texture that holds what is behind the blur gets its room
            // here, once, so that the copy below only writes pixels into it.
            glBindTexture(GLenum(GL_TEXTURE_2D), scratch.source)
            glTexImage2D(GLenum(GL_TEXTURE_2D), 0, GL_RGB,
                         GLsizei(source.width), GLsizei(source.height), 0,
                         GLenum(GL_RGB), GLenum(GL_UNSIGNED_BYTE), nil)
            scratch.width = source.width
            scratch.height = source.height
            glBindFramebuffer(GLenum(GL_FRAMEBUFFER), scratch.framebuffer)
            glFramebufferTexture2D(GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0),
                                   GLenum(GL_TEXTURE_2D), scratch.texture, 0)
            let state = glCheckFramebufferStatus(GLenum(GL_FRAMEBUFFER))
            // Back to what the list was drawing into, which the copy below
            // reads from.
            glBindFramebuffer(GLenum(GL_FRAMEBUFFER), framebuffer)
            guard state == GLenum(GL_FRAMEBUFFER_COMPLETE) else {
                scratch.width = 0
                scratch.height = 0
                return false
            }
        }
        // The screen counts rows from the top and GL counts them from the
        // bottom, so the copy starts at the bottom edge of the source.
        // glCopyTexImage2D would give the texture its room again for every
        // frame, and a texture that is made again while the GPU still draws
        // into the framebuffer it reads from makes everything stop and wait.
        // glCopyTexSubImage2D writes into the room that is already there.
        glBindTexture(GLenum(GL_TEXTURE_2D), scratch.source)
        glCopyTexSubImage2D(GLenum(GL_TEXTURE_2D), 0, 0, 0,
                            GLint(source.x), GLint(screen.height - source.y - source.height),
                            GLsizei(source.width), GLsizei(source.height))
        return true
    }

    /// A texture that reads between its pixels. A blur takes wide steps, so
    /// each step must read what is between two pixels as well.
    private func smooth() -> GLuint {
        var texture: GLuint = 0
        glGenTextures(1, &texture)
        glBindTexture(GLenum(GL_TEXTURE_2D), texture)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MIN_FILTER), GL_LINEAR)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MAG_FILTER), GL_LINEAR)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_S), GL_CLAMP_TO_EDGE)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_T), GL_CLAMP_TO_EDGE)
        return texture
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

    private func set(color: UInt32, at location: GLint) {
        glUniform4f(location,
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
        varying vec2 pixel;
        void main() {
            point = texturePoint;
            pixel = position;
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

    /// A gradient. The coverage of the path is in the texture, and the
    /// colour comes from how far along the line the pixel is. Both colours
    /// are multiplied by their alpha, so one mixes into the other.
    private static let gradientFragment = """
        precision mediump float;
        uniform sampler2D image;
        uniform vec4 color;
        uniform vec4 colorTo;
        uniform vec2 axisStart;
        uniform vec2 axisEnd;
        varying vec2 point;
        varying vec2 pixel;
        void main() {
            vec2 line = axisEnd - axisStart;
            float square = dot(line, line);
            float part = 0.0;
            if (square > 0.0) {
                part = clamp(dot(pixel - axisStart, line) / square, 0.0, 1.0);
            }
            gl_FragColor = mix(color, colorTo, part) * texture2D(image, point).a;
        }
        """

    /// One pass of a blur: 17 steps along one direction.
    ///
    /// The first pass reads the copy of the screen and writes to a texture,
    /// so it takes its place from the quad. The second pass writes to the
    /// screen inside the path, so it takes its place from where the pixel
    /// is on the screen, and the coverage of the path from a second texture.
    private static let blurFragment = """
        precision mediump float;
        uniform sampler2D image;
        uniform sampler2D mask;
        uniform vec2 tap;
        uniform vec2 sourceOrigin;
        uniform vec2 sourceSize;
        uniform float useMask;
        uniform float fromScreen;
        varying vec2 point;
        varying vec2 pixel;
        void main() {
            vec2 at = mix(point, (pixel - sourceOrigin) / sourceSize, fromScreen);
            vec4 sum = vec4(0.0);
            for (int index = -8; index <= 8; index++) {
                sum += texture2D(image, at + tap * float(index));
            }
            vec3 average = sum.rgb / 17.0;
            float covered = mix(1.0, texture2D(mask, point).a, useMask);
            gl_FragColor = vec4(average * covered, covered);
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
            forceOpaque: glGetUniformLocation(id, "forceOpaque"),
            colorTo: glGetUniformLocation(id, "colorTo"),
            axisStart: glGetUniformLocation(id, "axisStart"),
            axisEnd: glGetUniformLocation(id, "axisEnd"),
            sourceOrigin: glGetUniformLocation(id, "sourceOrigin"),
            sourceSize: glGetUniformLocation(id, "sourceSize"),
            step: glGetUniformLocation(id, "tap"),
            mask: glGetUniformLocation(id, "mask"),
            useMask: glGetUniformLocation(id, "useMask"),
            fromScreen: glGetUniformLocation(id, "fromScreen"))
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
