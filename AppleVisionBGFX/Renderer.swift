//
//  Renderer.swift
//

import CompositorServices
import Metal
import MetalKit
import simd
import Spatial

// The 256 byte aligned size of our uniform structure
let alignedUniformsSize = (MemoryLayout<UniformsArray>.size + 0xFF) & -0x100

let maxBuffersInFlight = 3

enum RendererError: Error {
    case badVertexDescriptor
}

extension LayerRenderer.Clock.Instant.Duration {
    var timeInterval: TimeInterval {
        let nanoseconds = TimeInterval(components.attoseconds / 1_000_000_000)
        return TimeInterval(components.seconds) + (nanoseconds / TimeInterval(NSEC_PER_SEC))
    }
}

class Renderer {
    public let device: MTLDevice                // mario: this comes from the `layerRenderer.device`
    let commandQueue: MTLCommandQueue
    var dynamicUniformBuffer: MTLBuffer
    var pipelineState: MTLRenderPipelineState
    var depthState: MTLDepthStencilState
    var colorMap: MTLTexture

    let inFlightSemaphore = DispatchSemaphore(value: maxBuffersInFlight)

    var uniformBufferOffset = 0

    var uniformBufferIndex = 0

    var uniforms: UnsafeMutablePointer<UniformsArray>

    var rotation: Float = 0

    var mesh: MTKMesh

    let arSession: ARKitSession
    let worldTracking: WorldTrackingProvider
    let layerRenderer: LayerRenderer
    var bgfxAdapter: BgfxAdapter
    
    init(_ layerRenderer: LayerRenderer) {
        self.layerRenderer = layerRenderer
        
        bgfxAdapter = BgfxAdapter(layerRenderer)
        
        // RendererContextMtl::init() uses MTLDevice passed via g_platformData.context; If NULL then MTLCreateSystemDefaultDevice() is called - docs claim its available on iOS, tvOS and visiosOS!
        self.device = layerRenderer.device
        /* // But following way of getting the MTLDevice was also working on visionOS! I've tested it myself!
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("MTLCreateSystemDefaultDevice failed on visionOS")
        }
        self.device = device*/
        self.commandQueue = self.device.makeCommandQueue()!


        // --- Create the uniform buffer
        let uniformBufferSize = alignedUniformsSize * maxBuffersInFlight

        self.dynamicUniformBuffer = self.device.makeBuffer(length:uniformBufferSize,
                                                           options:[MTLResourceOptions.storageModeShared])!

        self.dynamicUniformBuffer.label = "UniformBuffer"

        uniforms = UnsafeMutableRawPointer(dynamicUniformBuffer.contents()).bindMemory(to:UniformsArray.self, capacity:1)

        
        // --- create vertex descriptor (ala Vertex Array Object, describing the layout of data in vertex buffers)
        let mtlVertexDescriptor = Renderer.buildMetalVertexDescriptor()

        
        // --- create the render pipeline (needs device, vertex descriptor and layer renderer)
        // Why it needs the instance of LayerRenderer for? For Render Target Attachment Formats and for VIEW COUNT (for Vertex Amplification)
        do {
            pipelineState = try Renderer.buildRenderPipelineWithDevice(device: device,
                                                                       layerRenderer: layerRenderer,
                                                                       mtlVertexDescriptor: mtlVertexDescriptor)
        } catch {
            fatalError("Unable to compile render pipeline state.  Error info: \(error)")
        }

        // --- Create the Depth Stencil state
        let depthStateDescriptor = MTLDepthStencilDescriptor()
        depthStateDescriptor.depthCompareFunction = MTLCompareFunction.greater
        depthStateDescriptor.isDepthWriteEnabled = true
        self.depthState = device.makeDepthStencilState(descriptor:depthStateDescriptor)!

        // --- create the mesh and texture
        do {
            mesh = try Renderer.buildMesh(device: device, mtlVertexDescriptor: mtlVertexDescriptor)
        } catch {
            fatalError("Unable to build MetalKit Mesh. Error info: \(error)")
        }

        do {
            colorMap = try Renderer.loadTexture(device: device, textureName: "ColorMap")
        } catch {
            fatalError("Unable to load texture. Error info: \(error)")
        }
        
        worldTracking = WorldTrackingProvider()
        arSession = ARKitSession()
    }
    
    func startRenderLoop() {
        Task {
            do {
                try await arSession.run([worldTracking])
            } catch {
                fatalError("Failed to initialize ARSession")
            }
            
            let renderThread = Thread {
                self.renderLoop()
            }
            renderThread.name = "Render Thread"
            renderThread.start()
        }
    }

    class func buildMetalVertexDescriptor() -> MTLVertexDescriptor {
        // Create a Metal vertex descriptor specifying how vertices will by laid out for input into our render
        //   pipeline and how we'll layout our Model IO vertices

        let mtlVertexDescriptor = MTLVertexDescriptor()

        mtlVertexDescriptor.attributes[VertexAttribute.position.rawValue].format = MTLVertexFormat.float3
        mtlVertexDescriptor.attributes[VertexAttribute.position.rawValue].offset = 0
        mtlVertexDescriptor.attributes[VertexAttribute.position.rawValue].bufferIndex = BufferIndex.meshPositions.rawValue

        mtlVertexDescriptor.attributes[VertexAttribute.texcoord.rawValue].format = MTLVertexFormat.float2
        mtlVertexDescriptor.attributes[VertexAttribute.texcoord.rawValue].offset = 0
        mtlVertexDescriptor.attributes[VertexAttribute.texcoord.rawValue].bufferIndex = BufferIndex.meshGenerics.rawValue

        mtlVertexDescriptor.layouts[BufferIndex.meshPositions.rawValue].stride = 12
        mtlVertexDescriptor.layouts[BufferIndex.meshPositions.rawValue].stepRate = 1
        mtlVertexDescriptor.layouts[BufferIndex.meshPositions.rawValue].stepFunction = MTLVertexStepFunction.perVertex

        mtlVertexDescriptor.layouts[BufferIndex.meshGenerics.rawValue].stride = 8
        mtlVertexDescriptor.layouts[BufferIndex.meshGenerics.rawValue].stepRate = 1
        mtlVertexDescriptor.layouts[BufferIndex.meshGenerics.rawValue].stepFunction = MTLVertexStepFunction.perVertex

        return mtlVertexDescriptor
    }

    class func buildRenderPipelineWithDevice(device: MTLDevice,
                                             layerRenderer: LayerRenderer,
                                             mtlVertexDescriptor: MTLVertexDescriptor) throws -> MTLRenderPipelineState {
        /// Build a render state pipeline object

        // mario: all Metal source files (ending in .metal) are compiled by XCode into a single "default library"
        //        Apple docs call "MTLLibrary" "A collection of Metal shader functions."
        //        it can be compiled during build or at runtime from a text string.
        let library = device.makeDefaultLibrary()

        // mario: grab the vertex and fragment shaders
        let vertexFunction = library?.makeFunction(name: "vertexShader")
        let fragmentFunction = library?.makeFunction(name: "fragmentShader")

        // mario: create the render pipeline descriptor (like Pipeline State Object)
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.label = "RenderPipeline"
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.vertexDescriptor = mtlVertexDescriptor

        // mario: this includes render target attachment formats!
        //        ----> THIS IS WHY WE NEED TO PASS THE LayerRenderer OBJECT!
        pipelineDescriptor.colorAttachments[0].pixelFormat = layerRenderer.configuration.colorFormat
        pipelineDescriptor.depthAttachmentPixelFormat = layerRenderer.configuration.depthFormat

        // mario: ... but also for the viewCount (which can be configured, depending on the layer configuration)
        //
        // mario: Vertex Amplification -> "Run draw commands that render to different outputs using the same vertex data multiple times."
        //        we can encode drawing commands that process the same vertex multiple times, one per render target.
        //        It generates copies of a command's vertex data for each render pipeline.
        //        ----> VERTEX AMPLIFICATION is more efficent than encoding the command multiple times with the same vertex because the GPU fetcches the vertex data only once!
        //        ----> e.g. VA can be used to implement CSM with amplification multiplier that's equal to the number of cascade levels!
        pipelineDescriptor.maxVertexAmplificationCount = layerRenderer.properties.viewCount
        
        return try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
    }

    class func buildMesh(device: MTLDevice,
                         mtlVertexDescriptor: MTLVertexDescriptor) throws -> MTKMesh {
        /// Create and condition mesh data to feed into a pipeline using the given vertex descriptor

        let metalAllocator = MTKMeshBufferAllocator(device: device)

        let mdlMesh = MDLMesh.newBox(withDimensions: SIMD3<Float>(4, 4, 4),
                                     segments: SIMD3<UInt32>(2, 2, 2),
                                     geometryType: MDLGeometryType.triangles,
                                     inwardNormals:false,
                                     allocator: metalAllocator)

        let mdlVertexDescriptor = MTKModelIOVertexDescriptorFromMetal(mtlVertexDescriptor)

        guard let attributes = mdlVertexDescriptor.attributes as? [MDLVertexAttribute] else {
            throw RendererError.badVertexDescriptor
        }
        attributes[VertexAttribute.position.rawValue].name = MDLVertexAttributePosition
        attributes[VertexAttribute.texcoord.rawValue].name = MDLVertexAttributeTextureCoordinate

        mdlMesh.vertexDescriptor = mdlVertexDescriptor

        return try MTKMesh(mesh:mdlMesh, device:device)
    }

    class func loadTexture(device: MTLDevice,
                           textureName: String) throws -> MTLTexture {
        /// Load texture data with optimal parameters for sampling

        let textureLoader = MTKTextureLoader(device: device)

        let textureLoaderOptions = [
            MTKTextureLoader.Option.textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
            MTKTextureLoader.Option.textureStorageMode: NSNumber(value: MTLStorageMode.`private`.rawValue)
        ]

        return try textureLoader.newTexture(name: textureName,
                                            scaleFactor: 1.0,
                                            bundle: nil,
                                            options: textureLoaderOptions)

    }

    private func updateDynamicBufferState() {
        /// Update the state of our uniform buffers before rendering

        uniformBufferIndex = (uniformBufferIndex + 1) % maxBuffersInFlight

        uniformBufferOffset = alignedUniformsSize * uniformBufferIndex

        uniforms = UnsafeMutableRawPointer(dynamicUniformBuffer.contents() + uniformBufferOffset).bindMemory(to:UniformsArray.self, capacity:1)
    }

    private func updateGameState(drawable: LayerRenderer.Drawable, deviceAnchor: DeviceAnchor?) {
        /// Update any game state before rendering
        
        let rotationAxis = SIMD3<Float>(1, 1, 0)
        let modelRotationMatrix = matrix4x4_rotation(radians: rotation, axis: rotationAxis)
        let modelTranslationMatrix = matrix4x4_translation(0.0, 0.0, -8.0)
        let modelMatrix = modelTranslationMatrix * modelRotationMatrix
        
        let simdDeviceAnchor = deviceAnchor?.originFromAnchorTransform ?? matrix_identity_float4x4

        func uniforms(forViewIndex viewIndex: Int) -> Uniforms {
            let view = drawable.views[viewIndex]
            let viewMatrix = (simdDeviceAnchor * view.transform).inverse
            let projection = ProjectiveTransform3D(leftTangent: Double(view.tangents[0]),
                                                   rightTangent: Double(view.tangents[1]),
                                                   topTangent: Double(view.tangents[2]),
                                                   bottomTangent: Double(view.tangents[3]),
                                                   nearZ: Double(drawable.depthRange.y),
                                                   farZ: Double(drawable.depthRange.x),
                                                   reverseZ: true)
            
            return Uniforms(projectionMatrix: .init(projection), modelViewMatrix: viewMatrix * modelMatrix)
        }
        
        self.uniforms[0].uniforms.0 = uniforms(forViewIndex: 0)
        if drawable.views.count > 1 {
            self.uniforms[0].uniforms.1 = uniforms(forViewIndex: 1)
        }
        
        rotation += 0.01
    }

    func renderFrame() {
        /// Per frame updates hare

        // mario: A Frame provides the Metal textures and information you need to render one of those images (provides Drawable type).
        // mario: A frame has two phases: update phase and encode (or "submission") phase. BGFX should be concerned only about the latter.
        // mario: LayerRenderer.Drawable.View tells where to draw our content in the provided textures.
        guard let frame = layerRenderer.queryNextFrame() else { return }
        
        frame.startUpdate()
        
        // Perform frame independent work
        
        frame.endUpdate()
        
        guard let timing = frame.predictTiming() else { return }
        LayerRenderer.Clock().wait(until: timing.optimalInputTime)
        
        
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            fatalError("Failed to create command buffer")
        }
        
        // mario: TODO: We should make this available from BGFX's `swapChain->currentDrawableTexture()` function.
        //        currently this function uses `m_metalLayer.nextDrawable` (which in our case is not available?)...
        //        ---> (?) unless `m_drawableTexture` is set to anything but NULL?
        //        the CAMetalLayer holds a small pool of drawables (just like Layer renderer), each wrapped in CAMetalDrawable
        guard let drawable = frame.queryDrawable() else { return }
        
        _ = inFlightSemaphore.wait(timeout: DispatchTime.distantFuture)
        
        frame.startSubmission()
        
        let time = LayerRenderer.Clock.Instant.epoch.duration(to: drawable.frameTiming.presentationTime).timeInterval
        let deviceAnchor = worldTracking.queryDeviceAnchor(atTimestamp: time)
        
        drawable.deviceAnchor = deviceAnchor
        
        let semaphore = inFlightSemaphore
        commandBuffer.addCompletedHandler { (_ commandBuffer)-> Swift.Void in
            semaphore.signal()
        }
        
        self.updateDynamicBufferState()
        
        self.updateGameState(drawable: drawable, deviceAnchor: deviceAnchor)
        
        // mario: some of this renderPassDescriptor filling code is in RendererContextMtl::setFrameBuffer()
        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = drawable.colorTextures[0]
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.0)
        renderPassDescriptor.depthAttachment.texture = drawable.depthTextures[0]
        renderPassDescriptor.depthAttachment.loadAction = .clear
        renderPassDescriptor.depthAttachment.storeAction = .store
        renderPassDescriptor.depthAttachment.clearDepth = 0.0
        renderPassDescriptor.rasterizationRateMap = drawable.rasterizationRateMaps.first
        if layerRenderer.configuration.layout == .layered {
            renderPassDescriptor.renderTargetArrayLength = drawable.views.count
        }
        
        /// Final pass rendering code here
        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            fatalError("Failed to create render encoder")
        }
    
        renderEncoder.label = "Primary Render Encoder"
        
        renderEncoder.pushDebugGroup("Draw Box")
        
        renderEncoder.setCullMode(.back)
        
        renderEncoder.setFrontFacing(.counterClockwise)
        
        renderEncoder.setRenderPipelineState(pipelineState)
        
        renderEncoder.setDepthStencilState(depthState)
        
        renderEncoder.setVertexBuffer(dynamicUniformBuffer, offset:uniformBufferOffset, index: BufferIndex.uniforms.rawValue)

        let viewports = drawable.views.map { $0.textureMap.viewport }
        
        renderEncoder.setViewports(viewports)
        
        if drawable.views.count > 1 {
            var viewMappings = (0..<drawable.views.count).map {
                MTLVertexAmplificationViewMapping(viewportArrayIndexOffset: UInt32($0),
                                                  renderTargetArrayIndexOffset: UInt32($0))
            }
            renderEncoder.setVertexAmplificationCount(viewports.count, viewMappings: &viewMappings)
        }

        
        for (index, element) in mesh.vertexDescriptor.layouts.enumerated() {
            guard let layout = element as? MDLVertexBufferLayout else {
                return
            }
            
            if layout.stride != 0 {
                let buffer = mesh.vertexBuffers[index]
                renderEncoder.setVertexBuffer(buffer.buffer, offset:buffer.offset, index: index)
            }
        }
        
        renderEncoder.setFragmentTexture(colorMap, index: TextureIndex.color.rawValue)
        
        for submesh in mesh.submeshes {
            renderEncoder.drawIndexedPrimitives(type: submesh.primitiveType,
                                                indexCount: submesh.indexCount,
                                                indexType: submesh.indexType,
                                                indexBuffer: submesh.indexBuffer.buffer,
                                                indexBufferOffset: submesh.indexBuffer.offset)
            
        }
        
        renderEncoder.popDebugGroup()
        
        renderEncoder.endEncoding()
        
        drawable.encodePresent(commandBuffer: commandBuffer)
        
        commandBuffer.commit()
        
        frame.endSubmission()
    }
    
    func renderLoop() { // mario: call `self.renderFrame()` if the `layerRender.state` allows it
        while true {
            if layerRenderer.state == .invalidated {
                print("Layer is invalidated")
                bgfxAdapter.shutdown()
                return
            } else if layerRenderer.state == .paused {
                layerRenderer.waitUntilRunning()
                continue
            } else {
                autoreleasepool {
                    bgfxAdapter.initialize()
                    // self.renderFrame()
                    bgfxAdapter.render()
                }
            }
        }
    }
}

// Generic matrix math utility functions
func matrix4x4_rotation(radians: Float, axis: SIMD3<Float>) -> matrix_float4x4 {
    let unitAxis = normalize(axis)
    let ct = cosf(radians)
    let st = sinf(radians)
    let ci = 1 - ct
    let x = unitAxis.x, y = unitAxis.y, z = unitAxis.z
    return matrix_float4x4.init(columns:(vector_float4(    ct + x * x * ci, y * x * ci + z * st, z * x * ci - y * st, 0),
                                         vector_float4(x * y * ci - z * st,     ct + y * y * ci, z * y * ci + x * st, 0),
                                         vector_float4(x * z * ci + y * st, y * z * ci - x * st,     ct + z * z * ci, 0),
                                         vector_float4(                  0,                   0,                   0, 1)))
}

func matrix4x4_translation(_ translationX: Float, _ translationY: Float, _ translationZ: Float) -> matrix_float4x4 {
    return matrix_float4x4.init(columns:(vector_float4(1, 0, 0, 0),
                                         vector_float4(0, 1, 0, 0),
                                         vector_float4(0, 0, 1, 0),
                                         vector_float4(translationX, translationY, translationZ, 1)))
}

func radians_from_degrees(_ degrees: Float) -> Float {
    return (degrees / 180) * .pi
}
