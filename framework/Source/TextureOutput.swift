#if os(Linux)
#if GLES
    import COpenGLES.gles2
    #else
    import COpenGL
#endif
#else
#if GLES
    import OpenGLES
    #else
    import OpenGL.GL3
#endif
#endif

public class TextureOutput: ImageConsumer {
    public var newTextureAvailableCallback: ((GLuint) -> Void)?
    
    public let sources = SourceContainer()
    public let maximumInputs: UInt = 1
    
    #if DEBUG
    public var debugRenderInfo: String = ""
    #endif
    
    public func newFramebufferAvailable(_ framebuffer: Framebuffer, fromSourceIndex: UInt) {
        #if DEBUG
        let startTime = CACurrentMediaTime()
        defer {
            debugRenderInfo = """
{
    TextureOutput: {
        input: \(framebuffer.debugRenderInfo),
        output: { size: \(framebuffer.size.width * framebuffer.size.height * 4)  type: TextureCallback },
        time: \((CACurrentMediaTime() - startTime) * 1000.0)ms
    }
},
"""
        }
        #endif
        newTextureAvailableCallback?(framebuffer.texture)
        // TODO: Maybe extend the lifetime of the texture past this if needed
        framebuffer.unlock()
    }
}
