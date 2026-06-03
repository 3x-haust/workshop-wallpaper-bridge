#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <ScreenSaver/ScreenSaver.h>

@interface WorkshopWallpaperLockScreenSaverView : ScreenSaverView
@property(nonatomic, strong) AVPlayer *player;
@property(nonatomic, strong) AVPlayerLayer *playerLayer;
@property(nonatomic, strong) CALayer *imageLayer;
@property(nonatomic, strong) CATextLayer *fallbackLayer;
@property(nonatomic, strong) id endObserver;
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
    if ([self canUseVideoAtPath:sourcePath]) {
        [self showVideoAtURL:[NSURL fileURLWithPath:sourcePath] displayMode:displayMode];
        return;
    }

    NSString *imagePath = [configuration[@"imagePath"] isKindOfClass:NSString.class]
        ? configuration[@"imagePath"]
        : nil;
    if ([self canUseImageAtPath:imagePath]) {
        [self showImageAtURL:[NSURL fileURLWithPath:imagePath] displayMode:displayMode];
        return;
    }

    [self showFallbackMessage:@"Workshop Wallpaper Bridge has no playable Screen Saver media selected."];
}

- (NSDictionary *)readConfiguration {
    NSURL *applicationSupport = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory
                                                                      inDomains:NSUserDomainMask].firstObject;
    NSURL *configurationURL = [[[applicationSupport URLByAppendingPathComponent:@"WorkshopWallpaperBridge"]
        URLByAppendingPathComponent:@"LockScreen"] URLByAppendingPathComponent:@"active.json"];
    NSData *data = [NSData dataWithContentsOfURL:configurationURL];
    if (!data) {
        return @{};
    }
    NSDictionary *configuration = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [configuration isKindOfClass:NSDictionary.class] ? configuration : @{};
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

- (void)showVideoAtURL:(NSURL *)url displayMode:(NSString *)displayMode {
    [self removeContent];
    AVPlayerItem *item = [AVPlayerItem playerItemWithURL:url];
    self.player = [AVPlayer playerWithPlayerItem:item];
    self.player.muted = YES;
    self.player.actionAtItemEnd = AVPlayerActionAtItemEndNone;

    self.playerLayer = [AVPlayerLayer playerLayerWithPlayer:self.player];
    self.playerLayer.backgroundColor = NSColor.blackColor.CGColor;
    self.playerLayer.videoGravity = [self videoGravityForDisplayMode:displayMode];
    [self.layer addSublayer:self.playerLayer];
    [self layoutContent];

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

- (void)showImageAtURL:(NSURL *)url displayMode:(NSString *)displayMode {
    [self removeContent];
    NSImage *image = [[NSImage alloc] initWithContentsOfURL:url];
    CGImageRef cgImage = [image CGImageForProposedRect:NULL context:nil hints:nil];
    if (!cgImage) {
        return;
    }
    self.imageLayer = [CALayer layer];
    self.imageLayer.contents = (__bridge id)cgImage;
    self.imageLayer.contentsGravity = [self contentsGravityForDisplayMode:displayMode];
    self.imageLayer.backgroundColor = NSColor.blackColor.CGColor;
    [self.layer addSublayer:self.imageLayer];
    [self layoutContent];
}

- (void)removeContent {
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
}

- (void)layoutContent {
    self.layer.frame = self.bounds;
    self.playerLayer.frame = self.bounds;
    self.imageLayer.frame = self.bounds;
    self.fallbackLayer.frame = NSInsetRect(self.bounds, 32.0, 32.0);
}

- (void)showFallbackMessage:(NSString *)message {
    [self removeContent];
    self.layer.backgroundColor = [NSColor colorWithCalibratedWhite:0.08 alpha:1.0].CGColor;
    self.fallbackLayer = [CATextLayer layer];
    self.fallbackLayer.string = [NSString stringWithFormat:@"Workshop Wallpaper Bridge\n%@", message];
    self.fallbackLayer.alignmentMode = kCAAlignmentCenter;
    self.fallbackLayer.foregroundColor = NSColor.secondaryLabelColor.CGColor;
    self.fallbackLayer.fontSize = 22.0;
    self.fallbackLayer.wrapped = YES;
    self.fallbackLayer.contentsScale = NSScreen.mainScreen.backingScaleFactor;
    [self.layer addSublayer:self.fallbackLayer];
    [self layoutContent];
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
