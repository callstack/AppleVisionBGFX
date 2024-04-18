import CompositorServices
import Metal
import MetalKit
import simd
import Spatial

class Renderer {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let arSession: ARKitSession
    let worldTracking: WorldTrackingProvider
    let layerRenderer: LayerRenderer
    var bgfxAdapter: BgfxAdapter
    
    init(_ layerRenderer: LayerRenderer) {
        self.layerRenderer = layerRenderer
        bgfxAdapter = BgfxAdapter(layerRenderer)
        self.device = layerRenderer.device
        self.commandQueue = self.device.makeCommandQueue()!
      
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
                    bgfxAdapter.render()
                }
            }
        }
    }
}
