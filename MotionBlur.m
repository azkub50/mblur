// MotionBlur.m - frame-blending motion blur for Minecraft Bedrock (iOS)
// Hooks Metal's present step: blends each frame with the previous one.
// Strength 0.0 = off, 0.9 = very smeary. Default 0.45.
// Optional: set NSUserDefaults key "MBStrength" (float) to override.

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <objc/runtime.h>

static float gStrength = 0.45f;
static id<MTLRenderPipelineState> gPSO;
static MTLPixelFormat gPF;
static id<MTLTexture> gTmp, gHist;
static BOOL gHistValid;

static id (*orig_nextDrawable)(id, SEL);
static void (*orig_present)(id, SEL, id);

static NSString *const kShader =
@"#include <metal_stdlib>\n"
"using namespace metal;\n"
"struct V { float4 p [[position]]; float2 uv; };\n"
"vertex V mb_vs(uint i [[vertex_id]]) {\n"
"  float2 p = float2(float((i << 1) & 2), float(i & 2));\n"
"  V o; o.p = float4(p * 2.0 - 1.0, 0.0, 1.0); o.uv = float2(p.x, 1.0 - p.y); return o;\n"
"}\n"
"fragment float4 mb_fs(V in [[stage_in]], texture2d<float> a [[texture(0)]],\n"
"                      texture2d<float> b [[texture(1)]], constant float &s [[buffer(0)]]) {\n"
"  constexpr sampler sm(filter::linear, address::clamp_to_edge);\n"
"  return mix(a.sample(sm, in.uv), b.sample(sm, in.uv), s);\n"
"}\n";

static void MBEncode(id<MTLCommandBuffer> cb, id<CAMetalDrawable> d) {
    if (gStrength <= 0.001f) return;
    id<MTLTexture> cur = d.texture;
    if (!cur || cur.framebufferOnly) return;
    id<MTLDevice> dev = cb.device;
    NSUInteger w = cur.width, h = cur.height;
    MTLPixelFormat pf = cur.pixelFormat;

    if (!gPSO || gPF != pf) {
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:kShader options:nil error:&err];
        if (!lib) return;
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [lib newFunctionWithName:@"mb_vs"];
        pd.fragmentFunction = [lib newFunctionWithName:@"mb_fs"];
        pd.colorAttachments[0].pixelFormat = pf;
        gPSO = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
        if (!gPSO) return;
        gPF = pf;
        gTmp = nil; gHist = nil;
    }
    if (!gTmp || gTmp.width != w || gTmp.height != h) {
        MTLTextureDescriptor *td =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pf width:w height:h mipmapped:NO];
        td.usage = MTLTextureUsageShaderRead;
        td.storageMode = MTLStorageModePrivate;
        gTmp = [dev newTextureWithDescriptor:td];
        gHist = [dev newTextureWithDescriptor:td];
        gHistValid = NO;
        if (!gTmp || !gHist) return;
    }

    MTLSize size = MTLSizeMake(w, h, 1);
    MTLOrigin o0 = MTLOriginMake(0, 0, 0);

    if (!gHistValid) {
        id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
        [b copyFromTexture:cur sourceSlice:0 sourceLevel:0 sourceOrigin:o0 sourceSize:size
                 toTexture:gHist destinationSlice:0 destinationLevel:0 destinationOrigin:o0];
        [b endEncoding];
        gHistValid = YES;
        return;
    }

    // 1) copy current frame to tmp
    id<MTLBlitCommandEncoder> b1 = [cb blitCommandEncoder];
    [b1 copyFromTexture:cur sourceSlice:0 sourceLevel:0 sourceOrigin:o0 sourceSize:size
              toTexture:gTmp destinationSlice:0 destinationLevel:0 destinationOrigin:o0];
    [b1 endEncoding];

    // 2) draw mix(tmp, hist, strength) into the drawable
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = cur;
    rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
    [re setRenderPipelineState:gPSO];
    [re setFragmentTexture:gTmp atIndex:0];
    [re setFragmentTexture:gHist atIndex:1];
    float s = gStrength;
    [re setFragmentBytes:&s length:sizeof(s) atIndex:0];
    [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [re endEncoding];

    // 3) blended result becomes next frame's history
    id<MTLBlitCommandEncoder> b2 = [cb blitCommandEncoder];
    [b2 copyFromTexture:cur sourceSlice:0 sourceLevel:0 sourceOrigin:o0 sourceSize:size
              toTexture:gHist destinationSlice:0 destinationLevel:0 destinationOrigin:o0];
    [b2 endEncoding];
}

static id hook_nextDrawable(CAMetalLayer *self, SEL _cmd) {
    if (self.framebufferOnly) self.framebufferOnly = NO;
    return orig_nextDrawable(self, _cmd);
}

static void hook_present(id<MTLCommandBuffer> self, SEL _cmd, id drawable) {
    @try {
        if ([drawable conformsToProtocol:@protocol(CAMetalDrawable)])
            MBEncode(self, (id<CAMetalDrawable>)drawable);
    } @catch (__unused NSException *e) {}
    orig_present(self, _cmd, drawable);
}

__attribute__((constructor))
static void MBInit(void) {
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:@"MBStrength"];
    if (v) gStrength = fmaxf(0.0f, fminf(0.92f, [v floatValue]));

    Method m = class_getInstanceMethod([CAMetalLayer class], @selector(nextDrawable));
    if (m) {
        orig_nextDrawable = (void *)method_getImplementation(m);
        method_setImplementation(m, (IMP)hook_nextDrawable);
    }

    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    id<MTLCommandQueue> q = [dev newCommandQueue];
    id<MTLCommandBuffer> cb = [q commandBuffer];
    Class cls = object_getClass(cb);
    Method pm = class_getInstanceMethod(cls, @selector(presentDrawable:));
    if (pm) {
        orig_present = (void *)method_getImplementation(pm);
        method_setImplementation(pm, (IMP)hook_present);
    }
}
