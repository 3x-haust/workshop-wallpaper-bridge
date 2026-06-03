#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <ScreenSaver/ScreenSaver.h>
#import <pwd.h>
#import <unistd.h>

static void *WorkshopWallpaperPlayerItemStatusContext = &WorkshopWallpaperPlayerItemStatusContext;

@interface WorkshopWallpaperLockScreenSaverView : ScreenSaverView
@property(nonatomic, strong) AVPlayer *player;
@property(nonatomic, strong) AVPlayerLayer *playerLayer;
@property(nonatomic, strong) CALayer *imageLayer;
@property(nonatomic, strong) CATextLayer *fallbackLayer;
@property(nonatomic, strong) AVPlayerItem *observedPlayerItem;
@property(nonatomic, strong) id endObserver;
@property(nonatomic, strong) NSImage *fallbackImage;
@property(nonatomic, copy) NSString *fallbackDisplayMode;
@property(nonatomic, copy) NSString *fallbackMessage;
@end

@implementation WorkshopWallpaperLockScreenSaverView

- (instancetype)initWithFrame:(NSRect)frame isPreview:(BOOL)isPreview {
    self = [super initWithFrame:frame isPreview:isPreview];
    if (self) {
        self.wantsLayer = YES;
        self.layer = [CALayer layer];
        self.layer.backgroundColor = NSColor.blackColor.CGColor;
        [self setAnimationTimeInterval:1.0 / 30.0];
        [self reloadContent];
    }
    return self;
}

- (void)dealloc {
    [self removeContent];
}

- (void)startAnimation {
    [super startAnimation];
    [self reloadContent];
    [self.player play];
}

- (void)stopAnimation {
    [self.player pause];
    [super stopAnimation];
}

- (void)animateOneFrame {
    [self layoutContent];
}

- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    [self layoutContent];
}

- (void)reloadContent {
    NSDictionary *configuration = [self readConfiguration];
    if (![configuration[@"enabled"] boolValue]) {
        [self showFallbackMessage:@"Choose it in Wallpaper settings, then enable Screen Saver animation in Workshop Wallpaper Bridge."];
        return;
    }

    NSString *displayMode = [configuration[@"displayMode"] isKindOfClass:NSString.class]
        ? configuration[@"displayMode"]
        : @"fit";
    NSString *sourcePath = [configuration[@"sourcePath"] isKindOfClass:NSString.class]
        ? configuration[@"sourcePath"]
        : nil;
    NSString *imagePath = [configuration[@"imagePath"] isKindOfClass:NSString.class]
        ? configuration[@"imagePath"]
        : nil;
    if ([self canUseVideoAtPath:sourcePath]) {
        NSURL *fallbackImageURL = [self canUseImageAtPath:imagePath] ? [NSURL fileURLWithPath:imagePath] : nil;
        [self showVideoAtURL:[NSURL fileURLWithPath:sourcePath] fallbackImageURL:fallbackImageURL displayMode:displayMode];
        return;
    }

    if ([self canUseImageAtPath:imagePath]) {
        [self showImageAtURL:[NSURL fileURLWithPath:imagePath] displayMode:displayMode];
        return;
    }

    [self showFallbackMessage:@"No playable Screen Saver media selected."];
}

- (NSDictionary *)readConfiguration {
    for (NSURL *configurationURL in [self configurationURLs]) {
        NSData *data = [NSData dataWithContentsOfURL:configurationURL];
        if (!data) {
            continue;
        }
        NSDictionary *configuration = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if ([configuration isKindOfClass:NSDictionary.class]) {
            return configuration;
        }
    }
    return @{};
}

- (NSArray<NSURL *> *)configurationURLs {
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    NSURL *realHomeApplicationSupport = [self realHomeApplicationSupportURL];
    if (realHomeApplicationSupport) {
        [urls addObject:[self configurationURLFromApplicationSupport:realHomeApplicationSupport]];
    }

    NSURL *applicationSupport = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory
                                                                      inDomains:NSUserDomainMask].firstObject;
    if (applicationSupport) {
        NSURL *containerURL = [self configurationURLFromApplicationSupport:applicationSupport];
        if (![urls containsObject:containerURL]) {
            [urls addObject:containerURL];
        }
    }
    return urls;
}

- (NSURL *)configurationURLFromApplicationSupport:(NSURL *)applicationSupport {
    return [[[applicationSupport URLByAppendingPathComponent:@"WorkshopWallpaperBridge"]
        URLByAppendingPathComponent:@"LockScreen"] URLByAppendingPathComponent:@"active.json"];
}

- (NSURL *)realHomeApplicationSupportURL {
    struct passwd *password = getpwuid(getuid());
    if (!password || !password->pw_dir) {
        return nil;
    }
    NSString *homePath = [NSString stringWithUTF8String:password->pw_dir];
    if (homePath.length == 0) {
        return nil;
    }
    return [[NSURL fileURLWithPath:homePath] URLByAppendingPathComponent:@"Library/Application Support"];
}

- (BOOL)canUseVideoAtPath:(NSString *)path {
    if (path.length == 0 || ![NSFileManager.defaultManager fileExistsAtPath:path]) {
        return NO;
    }
    NSString *extension = path.pathExtension.lowercaseString;
    return [@[@"mp4", @"mov", @"m4v"] containsObject:extension];
}

- (BOOL)canUseImageAtPath:(NSString *)path {
    return path.length > 0 && [NSFileManager.defaultManager fileExistsAtPath:path];
}

- (void)showVideoAtURL:(NSURL *)url fallbackImageURL:(NSURL *)fallbackImageURL displayMode:(NSString *)displayMode {
    [self removeContent];
    BOOL hasFallbackImage = fallbackImageURL != nil;
    if (hasFallbackImage) {
        [self showImageAtURL:fallbackImageURL displayMode:displayMode];
    }

    AVPlayerItem *item = [AVPlayerItem playerItemWithURL:url];
    self.player = [AVPlayer playerWithPlayerItem:item];
    self.player.muted = YES;
    self.player.actionAtItemEnd = AVPlayerActionAtItemEndNone;

    self.playerLayer = [AVPlayerLayer playerLayerWithPlayer:self.player];
    self.playerLayer.backgroundColor = NSColor.clearColor.CGColor;
    self.playerLayer.opaque = NO;
    self.playerLayer.hidden = hasFallbackImage;
    self.playerLayer.videoGravity = [self videoGravityForDisplayMode:displayMode];
    [self.layer addSublayer:self.playerLayer];
    [self layoutContent];
    if (hasFallbackImage) {
        self.observedPlayerItem = item;
        [item addObserver:self
               forKeyPath:@"status"
                  options:NSKeyValueObservingOptionNew
                  context:WorkshopWallpaperPlayerItemStatusContext];
        if (item.status == AVPlayerItemStatusReadyToPlay) {
            [self revealVideoPlayback];
        }
    }

    __weak typeof(self) weakSelf = self;
    self.endObserver = [NSNotificationCenter.defaultCenter addObserverForName:AVPlayerItemDidPlayToEndTimeNotification
                                                                       object:item
                                                                        queue:NSOperationQueue.mainQueue
                                                                   usingBlock:^(__unused NSNotification *notification) {
        [item seekToTime:kCMTimeZero completionHandler:^(__unused BOOL finished) {
            [weakSelf.player play];
        }];
    }];
    [self.player play];
}

- (void)revealVideoPlayback {
    self.playerLayer.hidden = NO;
    [self.player play];
}

- (void)showImageAtURL:(NSURL *)url displayMode:(NSString *)displayMode {
    [self removeContent];
    NSImage *image = [[NSImage alloc] initWithContentsOfURL:url];
    self.fallbackImage = image;
    self.fallbackDisplayMode = displayMode;
    self.fallbackMessage = nil;
    [self setNeedsDisplay:YES];
    CGImageRef cgImage = [image CGImageForProposedRect:NULL context:nil hints:nil];
    if (!cgImage) {
        return;
    }
    self.layer.contents = (__bridge id)cgImage;
    self.layer.contentsGravity = [self contentsGravityForDisplayMode:displayMode];
    self.imageLayer = [CALayer layer];
    self.imageLayer.contents = (__bridge id)cgImage;
    self.imageLayer.contentsGravity = [self contentsGravityForDisplayMode:displayMode];
    self.imageLayer.backgroundColor = NSColor.blackColor.CGColor;
    [self.layer addSublayer:self.imageLayer];
    [self layoutContent];
}

- (void)removeContent {
    if (self.observedPlayerItem) {
        [self.observedPlayerItem removeObserver:self
                                     forKeyPath:@"status"
                                        context:WorkshopWallpaperPlayerItemStatusContext];
        self.observedPlayerItem = nil;
    }
    if (self.endObserver) {
        [NSNotificationCenter.defaultCenter removeObserver:self.endObserver];
        self.endObserver = nil;
    }
    [self.player pause];
    self.player = nil;
    [self.playerLayer removeFromSuperlayer];
    self.playerLayer = nil;
    [self.imageLayer removeFromSuperlayer];
    self.imageLayer = nil;
    [self.fallbackLayer removeFromSuperlayer];
    self.fallbackLayer = nil;
    self.layer.contents = nil;
    self.fallbackImage = nil;
    self.fallbackDisplayMode = nil;
    self.fallbackMessage = nil;
    [self setNeedsDisplay:YES];
}

- (void)layoutContent {
    self.layer.frame = self.bounds;
    self.playerLayer.frame = self.bounds;
    self.imageLayer.frame = self.bounds;
    self.fallbackLayer.frame = NSInsetRect(self.bounds, 32.0, 32.0);
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)rect {
    [NSColor.blackColor setFill];
    NSRectFill(rect);

    if (self.fallbackImage) {
        NSRect imageRect = [self fallbackImageRectForImageSize:self.fallbackImage.size displayMode:self.fallbackDisplayMode];
        [self.fallbackImage drawInRect:imageRect
                              fromRect:NSZeroRect
                             operation:NSCompositingOperationSourceOver
                              fraction:1.0
                        respectFlipped:YES
                                 hints:nil];
        return;
    }

    if (self.fallbackMessage.length == 0) {
        return;
    }

    NSMutableParagraphStyle *paragraphStyle = [[NSMutableParagraphStyle alloc] init];
    paragraphStyle.alignment = NSTextAlignmentCenter;
    NSDictionary<NSAttributedStringKey, id> *attributes = @{
        NSFontAttributeName: [NSFont systemFontOfSize:22.0 weight:NSFontWeightRegular],
        NSForegroundColorAttributeName: NSColor.secondaryLabelColor,
        NSParagraphStyleAttributeName: paragraphStyle,
    };
    NSRect textRect = NSInsetRect(self.bounds, 32.0, 32.0);
    [self.fallbackMessage drawInRect:textRect withAttributes:attributes];
}

- (NSRect)fallbackImageRectForImageSize:(NSSize)imageSize displayMode:(NSString *)displayMode {
    NSRect bounds = self.bounds;
    if ([displayMode isEqualToString:@"stretch"] || imageSize.width <= 0.0 || imageSize.height <= 0.0) {
        return bounds;
    }

    CGFloat widthRatio = NSWidth(bounds) / imageSize.width;
    CGFloat heightRatio = NSHeight(bounds) / imageSize.height;
    CGFloat scale = [displayMode isEqualToString:@"fill"] ? MAX(widthRatio, heightRatio) : MIN(widthRatio, heightRatio);
    NSSize scaledSize = NSMakeSize(imageSize.width * scale, imageSize.height * scale);
    return NSMakeRect(NSMidX(bounds) - scaledSize.width / 2.0,
                      NSMidY(bounds) - scaledSize.height / 2.0,
                      scaledSize.width,
                      scaledSize.height);
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary<NSKeyValueChangeKey, id> *)change
                       context:(void *)context {
    if (context == WorkshopWallpaperPlayerItemStatusContext) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (object != self.observedPlayerItem) {
                return;
            }
            if (self.observedPlayerItem.status == AVPlayerItemStatusReadyToPlay) {
                [self revealVideoPlayback];
            }
            if (self.observedPlayerItem.status == AVPlayerItemStatusFailed) {
                self.playerLayer.hidden = YES;
            }
        });
        return;
    }
    [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
}

- (void)showFallbackMessage:(NSString *)message {
    [self removeContent];
    self.fallbackImage = nil;
    self.fallbackDisplayMode = nil;
    self.fallbackMessage = [NSString stringWithFormat:@"Workshop Wallpaper Bridge\n%@", message];
    self.layer.backgroundColor = [NSColor colorWithCalibratedWhite:0.08 alpha:1.0].CGColor;
    self.fallbackLayer = [CATextLayer layer];
    self.fallbackLayer.string = self.fallbackMessage;
    self.fallbackLayer.alignmentMode = kCAAlignmentCenter;
    self.fallbackLayer.foregroundColor = NSColor.secondaryLabelColor.CGColor;
    self.fallbackLayer.fontSize = 22.0;
    self.fallbackLayer.wrapped = YES;
    self.fallbackLayer.contentsScale = [self backingScaleFactor];
    [self.layer addSublayer:self.fallbackLayer];
    [self layoutContent];
}

- (CGFloat)backingScaleFactor {
    CGFloat scale = self.window.screen.backingScaleFactor;
    if (scale > 0.0) {
        return scale;
    }
    return 1.0;
}

- (AVLayerVideoGravity)videoGravityForDisplayMode:(NSString *)displayMode {
    if ([displayMode isEqualToString:@"fill"]) {
        return AVLayerVideoGravityResizeAspectFill;
    }
    if ([displayMode isEqualToString:@"stretch"]) {
        return AVLayerVideoGravityResize;
    }
    return AVLayerVideoGravityResizeAspect;
}

- (CALayerContentsGravity)contentsGravityForDisplayMode:(NSString *)displayMode {
    if ([displayMode isEqualToString:@"fill"]) {
        return kCAGravityResizeAspectFill;
    }
    if ([displayMode isEqualToString:@"stretch"]) {
        return kCAGravityResize;
    }
    return kCAGravityResizeAspect;
}

@end
