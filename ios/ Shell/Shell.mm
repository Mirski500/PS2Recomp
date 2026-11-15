// Shell.mm - minimal iOS host: Metal view locked to 60 fps, ISO picker, lifted-code status.
// It does NOT run the game: GS/DMA/VIF/SPU2/IOP are not implemented (see lift_bt3.py notes).
#import <UIKit/UIKit.h>
#import <MetalKit/MetalKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include "BT3Bridge.h"

// Shaders are compiled at runtime from source, so the build needs no Metal toolchain component.
static const char* kMSL = R"MSL(
#include <metal_stdlib>
using namespace metal;
struct VOut { float4 pos [[position]]; float2 uv; };
struct Uni { float time; float aspect; };
vertex VOut vs_main(uint vid [[vertex_id]]) {
    float2 p = float2(float((vid << 1) & 2u), float(vid & 2u));
    VOut o;
    o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = float2(p.x, 1.0 - p.y);
    return o;
}
// Placeholder cel-shading look: a light blob quantised into 4 flat bands.
fragment float4 fs_main(VOut in [[stage_in]], constant Uni& u [[buffer(0)]]) {
    float2 q = (in.uv - 0.5) * float2(u.aspect, 1.0);
    float d = length(q - 0.18 * float2(cos(u.time), sin(u.time)));
    float lit = clamp(1.0 - d * 1.6, 0.0, 1.0);
    float band = floor(lit * 4.0) / 4.0;
    float3 col = mix(float3(0.04, 0.06, 0.14), float3(1.0, 0.62, 0.12), band);
    return float4(col, 1.0);
}
)MSL";

@interface BT3ViewController : UIViewController <MTKViewDelegate, UIDocumentPickerDelegate>
@end

@implementation BT3ViewController {
    MTKView *_view;
    id<MTLDevice> _device;
    id<MTLCommandQueue> _queue;
    id<MTLRenderPipelineState> _pso;
    UILabel *_hud;
    UIButton *_pick;
    CFTimeInterval _t0, _fpsT0;
    int _frames;
    double _fps;
    NSURL *_isoURL;
    BOOL _accessing;
    NSString *_isoStatus;
    BOOL _shownPicker;
}

- (BOOL)prefersStatusBarHidden { return YES; }
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
    _t0 = _fpsT0 = CACurrentMediaTime();

    _hud = [UILabel new];
    _hud.translatesAutoresizingMaskIntoConstraints = NO;
    _hud.numberOfLines = 0;
    _hud.textColor = UIColor.whiteColor;
    _hud.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    _hud.shadowColor = UIColor.blackColor;
    _hud.shadowOffset = CGSizeMake(1, 1);

    _pick = [UIButton buttonWithType:UIButtonTypeSystem];
    _pick.translatesAutoresizingMaskIntoConstraints = NO;
    [_pick setTitle:@"Choose ISO…" forState:UIControlStateNormal];
    [_pick addTarget:self action:@selector(presentPicker) forControlEvents:UIControlEventTouchUpInside];

    _device = MTLCreateSystemDefaultDevice();
    NSString *gpuError = nil;
    if (!_device) {
        gpuError = @"No Metal device";
    } else {
        _view = [[MTKView alloc] initWithFrame:self.view.bounds device:_device];
        _view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _view.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
        _view.preferredFramesPerSecond = 60;   // lock to 60 even on 120 Hz ProMotion
        _view.delegate = self;
        [self.view addSubview:_view];
        _queue = [_device newCommandQueue];

        NSError *err = nil;
        id<MTLLibrary> lib = [_device newLibraryWithSource:[NSString stringWithUTF8String:kMSL]
                                                   options:nil error:&err];
        if (!lib) {
            gpuError = [NSString stringWithFormat:@"Shader compile failed: %@", err.localizedDescription];
        } else {
            MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
            d.vertexFunction = [lib newFunctionWithName:@"vs_main"];
            d.fragmentFunction = [lib newFunctionWithName:@"fs_main"];
            d.colorAttachments[0].pixelFormat = _view.colorPixelFormat;
            _pso = [_device newRenderPipelineStateWithDescriptor:d error:&err];
            if (!_pso) gpuError = [NSString stringWithFormat:@"Pipeline failed: %@", err.localizedDescription];
        }
    }
    [self.view addSubview:_hud];
    [self.view addSubview:_pick];
    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_hud.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:12],
        [_hud.topAnchor constraintEqualToAnchor:g.topAnchor constant:8],
        [_pick.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:12],
        [_pick.bottomAnchor constraintEqualToAnchor:g.bottomAnchor constant:-8],
    ]];

    [self adoptISO:[self findISO]];
    if (gpuError) _isoStatus = [NSString stringWithFormat:@"%@\n%@", gpuError, _isoStatus ?: @""];
    [self updateHUD];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (!_isoURL && !_shownPicker) { _shownPicker = YES; [self presentPicker]; }
}

- (void)dealloc {
    if (_accessing && _isoURL) [_isoURL stopAccessingSecurityScopedResource];
}

#pragma mark - ISO discovery

- (NSString *)documentsPath {
    return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
}

- (NSURL *)findISO {
    NSData *bm = [NSUserDefaults.standardUserDefaults dataForKey:@"iso_bookmark"];
    if (bm) {
        BOOL stale = NO; NSError *e = nil;
        NSURL *u = [NSURL URLByResolvingBookmarkData:bm options:0 relativeToURL:nil
                                 bookmarkDataIsStale:&stale error:&e];
        if (u && !stale) return u;
    }
    NSString *docs = [self documentsPath];
    for (NSString *n in [NSFileManager.defaultManager contentsOfDirectoryAtPath:docs error:nil]) {
        NSString *ext = n.pathExtension.lowercaseString;
        if ([ext isEqualToString:@"iso"] || [ext isEqualToString:@"bin"])
            return [NSURL fileURLWithPath:[docs stringByAppendingPathComponent:n]];
    }
    return nil;
}

// Takes ownership of security-scoped access and validates the image (ISO-9660 magic at sector 16).
- (void)adoptISO:(NSURL *)url {
    if (_accessing && _isoURL) { [_isoURL stopAccessingSecurityScopedResource]; _accessing = NO; }
    _isoURL = nil;
    if (!url) { _isoStatus = @"ISO: none. Put your own PS2 ISO in Files > BT3 Shell, or tap Choose ISO…"; return; }
    BOOL started = [url startAccessingSecurityScopedResource];
    NSError *e = nil;
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingFromURL:url error:&e];
    if (!fh) {
        if (started) [url stopAccessingSecurityScopedResource];
        _isoStatus = [NSString stringWithFormat:@"ISO: cannot open %@ (%@)", url.lastPathComponent, e.localizedDescription];
        return;
    }
    NSNumber *size = nil;
    [url getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
    NSData *magic = nil;
    if ([fh seekToOffset:16 * 2048 + 1 error:&e]) magic = [fh readDataUpToLength:5 error:&e];
    [fh closeAndReturnError:nil];
    BOOL ok = magic && magic.length == 5 && memcmp(magic.bytes, "CD001", 5) == 0;
    _isoURL = url; _accessing = started;
    _isoStatus = [NSString stringWithFormat:@"ISO: %@ (%.0f MiB) %@", url.lastPathComponent,
                  size.doubleValue / 1048576.0,
                  ok ? @"- ISO-9660 OK (2048-byte sectors)" : @"- NOT a plain 2048-byte ISO-9660 image"];
}

#pragma mark - picker

- (void)presentPicker {
    UIDocumentPickerViewController *p =
        [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeItem] asCopy:NO];
    p.delegate = self;
    p.allowsMultipleSelection = NO;
    [self presentViewController:p animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)c didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *u = urls.firstObject;
    if (!u) return;
    BOOL started = [u startAccessingSecurityScopedResource];
    NSError *e = nil;
    NSData *bm = [u bookmarkDataWithOptions:0 includingResourceValuesForKeys:nil relativeToURL:nil error:&e];
    if (bm) [NSUserDefaults.standardUserDefaults setObject:bm forKey:@"iso_bookmark"];
    if (started) [u stopAccessingSecurityScopedResource];   // adoptISO re-acquires and holds access
    [self adoptISO:u];
    [self updateHUD];
}

#pragma mark - HUD / rendering

- (void)updateHUD {
    int n = bt3_lifted_function_count();
    NSString *lifted = n < 0 ? @"lifted code: not linked (shell only)"
                             : [NSString stringWithFormat:@"lifted code: %d functions linked, text base 0x%08X (not executed)",
                                n, bt3_lifted_text_base()];
    _hud.text = [NSString stringWithFormat:@"%.1f fps (target 60)\n%@\n%@\nGame is NOT running: GS/DMA/VIF/SPU2/IOP not implemented.",
                 _fps, _isoStatus ?: @"", lifted];
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {}

- (void)drawInMTKView:(MTKView *)view {
    MTLRenderPassDescriptor *rpd = view.currentRenderPassDescriptor;
    id<CAMetalDrawable> drawable = view.currentDrawable;
    if (!rpd || !drawable || !_pso) return;
    id<MTLCommandBuffer> cb = [_queue commandBuffer];
    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rpd];
    struct { float time; float aspect; } u = {
        (float)(CACurrentMediaTime() - _t0),
        (float)(view.drawableSize.width / MAX(view.drawableSize.height, 1.0))
    };
    [enc setRenderPipelineState:_pso];
    [enc setFragmentBytes:&u length:sizeof(u) atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [enc endEncoding];
    [cb presentDrawable:drawable];
    [cb commit];

    _frames++;
    CFTimeInterval now = CACurrentMediaTime();
    if (now - _fpsT0 >= 1.0) {
        _fps = _frames / (now - _fpsT0);
        _frames = 0; _fpsT0 = now;
        [self updateHUD];
    }
}
@end

@interface SceneDelegate : UIResponder <UIWindowSceneDelegate>
@property (strong, nonatomic) UIWindow *window;
@end

@implementation SceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session
      options:(UISceneConnectionOptions *)options {
    if (![scene isKindOfClass:[UIWindowScene class]]) return;
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController = [BT3ViewController new];
    [self.window makeKeyAndVisible];
}
@end

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@end

@implementation AppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
