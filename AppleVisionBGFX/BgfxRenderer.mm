////
////  BgfxRenderer.m
////  bgfxVision
////
////  Created by Mariusz Pasinski on 17/03/2024.
////
//
#import <Foundation/Foundation.h>
#import <CompositorServices/CompositorServices.h>
#include <bgfx/c99/bgfx.h>

// Our BgfxRenderer MUST expose 2 public methods:
// init(cp_layer_renderer_t)
// startRenderLoop()

@interface BgfxRenderer: NSObject {
    // Private instance variables
    cp_layer_renderer_t m_layerRenderer;
}

-(id)init : (cp_layer_renderer_t)layerRenderer;
-(void)startRenderLoop;

-(void)setupRenderer;
-(void)renderFrame;
-(void)teardownRenderer;

@end



@implementation BgfxRenderer

-(id)init : (cp_layer_renderer_t)layerRenderer
{
    self = [super init];
    if (self) {
        m_layerRenderer = layerRenderer;
    }
    return self;
}

-(void)startRenderLoop
{
    //[self setupRenderer];
    bgfx_init_t init;
    bgfx_init_ctor(&init);
    
    init.type = BGFX_RENDERER_TYPE_METAL;
    init.platformData.nwh = (__bridge void*)m_layerRenderer;
    init.resolution.width = 2732;
    init.resolution.height = 2048;
    bgfx_init(&init);
    bgfx_set_debug(true);
    
    bgfx_set_view_clear(0, BGFX_CLEAR_COLOR | BGFX_CLEAR_DEPTH, 0x303030FF, 1.0, 0);
    
    bool is_rendering = true;
    while (is_rendering) @autoreleasepool {
        switch (cp_layer_renderer_get_state(m_layerRenderer)) {
            case cp_layer_renderer_state_paused:
                // Wait until the scene appears
                cp_layer_renderer_wait_until_running(m_layerRenderer);
                break;
                
            case cp_layer_renderer_state_running:
                // Renderer the next frame
                [self renderFrame];
                break;
                
            case cp_layer_renderer_state_invalidated:
                // Exit the render loop
                is_rendering = false;
                break;
        }
    }
    
    [self teardownRenderer];
}

-(void)setupRenderer
{
    /*bgfx_init_t init;
    bgfx_init_ctor(&init);
    
    init.type = BGFX_RENDERER_TYPE_METAL;
    //init.platformData.nwh = (__bridge void*)?;
    init.resolution.width = 2732;
    init.resolution.height = 2048;
    bgfx_init(&init);
    bgfx_set_debug(true);
    
    bgfx_set_view_clear(0, BGFX_CLEAR_COLOR | BGFX_CLEAR_DEPTH, 0x303030FF, 1.0, 0);*/
}

-(void)renderFrame
{
    // Get the next frame
    cp_frame_t frame = cp_layer_renderer_query_next_frame(m_layerRenderer);
    if (frame == NULL) { return; }
    
    // Fetch the predicted timing information
    cp_frame_timing_t timing = cp_frame_predict_timing(frame);
    if (timing == NULL) { return; }
    
    // Update the frame
    cp_frame_start_update(frame);
    
    // Update any position- or orientation-independent information
    //my_input_state input_state = my_engine_gather_inputs(timing);
    //my_engine_update_frame(timing, input_state);
    cp_frame_end_update(frame);
    
    
    // Wait until the optimal time for querying the input
    cp_time_wait_until(cp_frame_timing_get_optimal_input_time(timing));
    
    
    // Submit the frame
    cp_frame_start_submission(frame);
    cp_drawable_t drawable = cp_frame_query_drawable(frame);
    if (drawable == NULL) { return; }
    
    
    //cp_frame_timing_t timing = cp_drawable_get_frame_timing(frame);
    //ar_device_anchor_t anchor = my_engine_get_ar_device_anchor(engine, timing);
    //cp_drawable_set_ar_device_anchor(drawable, anchor);
    
    
    //my_engine_draw_and_submit_frame(engine, frame, drawable);
    
    cp_frame_end_submission(frame);
    
    
    /*bgfx_set_view_rect(0, 0, 0, width, height);
    
    bgfx_encoder_t* encoder = bgfx_encoder_begin(true);
    bgfx_encoder_touch(encoder, 0);
    bgfx_encoder_end(encoder);
    
    bgfx_frame(false);*/
}

-(void)teardownRenderer
{
    bgfx_shutdown();
}

@end
