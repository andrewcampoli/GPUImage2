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

// TODO: Add mechanism to purge framebuffers on low memory

public class FramebufferCache {
    var framebufferCache = [Int64: Set<Framebuffer>]()
    let context: OpenGLContext
    
    init(context: OpenGLContext) {
        self.context = context
    }
    
    public func requestFramebufferWithProperties(orientation: ImageOrientation, size: GLSize, textureOnly: Bool = false, minFilter: Int32 = GL_LINEAR, magFilter: Int32 = GL_LINEAR, wrapS: Int32 = GL_CLAMP_TO_EDGE, wrapT: Int32 = GL_CLAMP_TO_EDGE, internalFormat: Int32 = GL_RGBA, format: Int32 = GL_BGRA, type: Int32 = GL_UNSIGNED_BYTE, stencil: Bool = false) -> Framebuffer {
        __dispatch_assert_queue(context.serialDispatchQueue)
        let hash = hashForFramebufferWithProperties(orientation: orientation, size: size, textureOnly: textureOnly, minFilter: minFilter, magFilter: magFilter, wrapS: wrapS, wrapT: wrapT, internalFormat: internalFormat, format: format, type: type, stencil: stencil)
        let framebuffer: Framebuffer
        
        if framebufferCache.count > 10 {
            print("Warning: Runaway framebuffer cache with size: \(framebufferCache.count)")
        }
        
        if (framebufferCache[hash]?.count ?? -1) > 0 {
            // print("Restoring previous framebuffer")
            framebuffer = framebufferCache[hash]!.removeFirst()
            framebuffer.orientation = orientation
        } else {
            do {
                // debugPrint("Generating new framebuffer at size: \(size)")
                framebuffer = try Framebuffer(context: context, orientation: orientation, size: size, textureOnly: textureOnly, minFilter: minFilter, magFilter: magFilter, wrapS: wrapS, wrapT: wrapT, internalFormat: internalFormat, format: format, type: type, stencil: stencil)
                framebuffer.cache = self
            } catch {
                fatalError("Could not create a framebuffer of the size (\(size.width), \(size.height)), error: \(error)")
            }
        }
        return framebuffer
    }
    
    public func purgeAllUnassignedFramebuffers(sync: Bool = false) {
        if sync {
            context.runOperationSynchronously {
                self.framebufferCache.removeAll()
            }
        } else {
            context.runOperationAsynchronously {
                self.framebufferCache.removeAll()
            }
        }
    }
    
    func returnToCache(_ framebuffer: Framebuffer) {
        // sprint("Returning to cache: \(framebuffer)")
        context.runOperationSynchronously {
            if self.framebufferCache[framebuffer.hash] != nil {
                if self.framebufferCache[framebuffer.hash]!.contains(framebuffer) {
                    print("WARNING: add duplicated buffer to cache.")
                } else {
                    self.framebufferCache[framebuffer.hash]!.insert(framebuffer)
                }
            } else {
                self.framebufferCache[framebuffer.hash] = Set<Framebuffer>([framebuffer])
            }
        }
    }
}
