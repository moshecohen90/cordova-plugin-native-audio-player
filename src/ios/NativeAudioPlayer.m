#import "NativeAudioPlayer.h"
#import <MediaPlayer/MediaPlayer.h>
#import <objc/runtime.h>

/**
 * iOS side: AVQueuePlayer + MPNowPlayingInfoCenter / MPRemoteCommandCenter — the same
 * Now Playing card Apple Music uses. The queue advances natively (zero JS), so playback
 * survives a frozen background WebView. Every event carries the queue generation plus a
 * monotonic seq so JS can drop stale or duplicated deliveries. No periodic position
 * events; Now Playing is updated only on item change / play / pause / seek / rate.
 *
 * Queue items are verse SEGMENTS; items flagged boundary=true start a verse. The remote
 * next/previous commands seek by verse boundary natively.
 */

static void *kAbsIndexKey = &kAbsIndexKey;
static void *kCurrentItemCtx = &kCurrentItemCtx;
static void *kTimeControlCtx = &kTimeControlCtx;
static void *kItemStatusCtx = &kItemStatusCtx;

static BOOL napAudit(void) {
#ifdef DEBUG
    return YES;
#else
    return NO;
#endif
}

@interface NAPSynthJob : NSObject
@property (nonatomic, strong) AVSpeechSynthesizer *synth;
@property (nonatomic, strong) AVAudioFile *file;
@property (nonatomic) long long frames;
@property (nonatomic) double sampleRate;
@property (nonatomic, strong) NSMutableArray *timestamps;
@property (nonatomic, copy) NSString *callbackId;
@property (nonatomic, copy) NSString *cafPath;
@property (nonatomic, copy) NSString *sidecarPath;
@property (nonatomic) BOOL finished;
@end
@implementation NAPSynthJob
@end

@interface NativeAudioPlayer ()
@property (nonatomic, strong) AVQueuePlayer *player;
@property (nonatomic, copy) NSString *eventsCallbackId;
@property (nonatomic) long long generation;
@property (nonatomic) long long seq;
@property (nonatomic, copy) NSString *lastState;
@property (nonatomic, copy) NSString *lastReason;
@property (nonatomic) NSInteger lastReportedIndex;
@property (nonatomic) BOOL shouldBePlaying;
@property (nonatomic, copy) NSString *pauseReason;
@property (nonatomic) float requestedRate;
@property (nonatomic) UIBackgroundTaskIdentifier bufferKeepAlive;
@property (nonatomic, strong) NSMutableArray<NSDictionary*> *queueMeta;
@property (nonatomic, strong) NSMutableArray<AVPlayerItem*> *liveItems;
@property (nonatomic, strong) NSMutableDictionary *nowPlaying;
@property (nonatomic, copy) NSString *artworkUrl;
@property (nonatomic, strong) MPMediaItemArtwork *artwork;
@property (nonatomic) BOOL remoteCommandsRegistered;
@property (nonatomic) BOOL sessionObserversRegistered;
@property (nonatomic, strong) NSTimer *heartbeat;
@property (nonatomic, strong) NSMapTable<AVSpeechUtterance*, NAPSynthJob*> *synthJobs;
@property (nonatomic, strong) dispatch_queue_t synthQueue;
@property (nonatomic) long long stallToken;
@end

@implementation NativeAudioPlayer

- (void)pluginInitialize {
    self.bufferKeepAlive = UIBackgroundTaskInvalid;
    self.requestedRate = 1.0f;
    self.lastReportedIndex = -1;
    self.synthJobs = [NSMapTable strongToStrongObjectsMapTable];
    self.synthQueue = dispatch_queue_create("nap.synth", DISPATCH_QUEUE_SERIAL);
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(itemDidEnd:)
        name:AVPlayerItemDidPlayToEndTimeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(itemFailed:)
        name:AVPlayerItemFailedToPlayToEndTimeNotification object:nil];
    [self registerTestCommandObservers];
}

// Debug-only automation channel: `devicectl device notification post --name nap.test.<cmd>`
// reaches the RUNNING app without relaunching it (devicectl can otherwise deliver a URL
// only by relaunching, which kills the console stream and any active playback).
- (void)registerTestCommandObservers {
    if (!napAudit()) { return; }
    CFNotificationCenterRef center = CFNotificationCenterGetDarwinNotifyCenter();
    for (NSString *cmd in @[@"cfg.mp3", @"cfg.tts", @"cfg.mp3tts", @"cfg.mixed", @"play", @"play.start", @"stop"]) {
        CFNotificationCenterAddObserver(center, (__bridge const void *)self, napTestCommandCallback,
            (__bridge CFStringRef)[@"nap.test." stringByAppendingString:cmd], NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
    }
}

static void napTestCommandCallback(CFNotificationCenterRef center, void *observer, CFNotificationName name, const void *object, CFDictionaryRef userInfo) {
    NativeAudioPlayer *plugin = (__bridge NativeAudioPlayer *)observer;
    NSString *command = [(__bridge NSString *)name stringByReplacingOccurrencesOfString:@"nap.test." withString:@""];
    dispatch_async(dispatch_get_main_queue(), ^{
        [plugin emit:@"test" payload:@{ @"command": command }];
    });
}

#pragma mark - commands

- (void)setEvents:(CDVInvokedUrlCommand*)command {
    self.eventsCallbackId = command.callbackId;
    CDVPluginResult *r = [CDVPluginResult resultWithStatus:CDVCommandStatus_NO_RESULT];
    [r setKeepCallbackAsBool:YES];
    [self.commandDelegate sendPluginResult:r callbackId:command.callbackId];
}

- (void)setQueue:(CDVInvokedUrlCommand*)command {
    NSDictionary *opts = [command argumentAtIndex:0 withDefault:@{}];
    NSArray *items = opts[@"items"];
    if (![items isKindOfClass:[NSArray class]] || items.count == 0) { [self fail:command msg:@"empty queue"]; return; }

    [self configureSession];
    [self teardownPlayback];
    self.generation = [opts[@"generation"] longLongValue];
    self.lastState = nil;
    self.lastReason = nil;
    self.pauseReason = nil;
    self.queueMeta = [items mutableCopy];
    double rate = [opts[@"rate"] doubleValue];
    self.requestedRate = rate > 0 ? (float)rate : 1.0f;

    NSInteger start = [opts[@"startIndex"] integerValue];
    if (start < 0 || start >= (NSInteger)items.count) { start = 0; }
    NSArray<AVPlayerItem*> *built = [self buildItemsFromAbs:start];
    if (built.count == 0) { [self fail:command msg:@"no valid items"]; return; }

    self.player = [AVQueuePlayer queuePlayerWithItems:built];
    [self.player addObserver:self forKeyPath:@"currentItem"
                     options:NSKeyValueObservingOptionNew | NSKeyValueObservingOptionInitial
                     context:kCurrentItemCtx];
    [self.player addObserver:self forKeyPath:@"timeControlStatus"
                     options:NSKeyValueObservingOptionNew context:kTimeControlCtx];

    double startPosMs = [opts[@"startPositionMs"] doubleValue];
    if (startPosMs > 0) {
        [self.player seekToTime:CMTimeMakeWithSeconds(startPosMs / 1000.0, NSEC_PER_SEC)];
    }
    BOOL autoplay = opts[@"autoplay"] ? [opts[@"autoplay"] boolValue] : YES;
    self.shouldBePlaying = autoplay;
    if (autoplay) { [self applyPlay]; }
    [self startHeartbeat];
    [self ok:command];
}

- (void)appendQueue:(CDVInvokedUrlCommand*)command {
    NSDictionary *opts = [command argumentAtIndex:0 withDefault:@{}];
    NSArray *items = opts[@"items"];
    if (![items isKindOfClass:[NSArray class]] || items.count == 0) { [self fail:command msg:@"empty items"]; return; }
    if ([opts[@"generation"] longLongValue] != self.generation) { [self fail:command msg:@"stale generation"]; return; }
    if (self.player == nil || self.queueMeta == nil) { [self fail:command msg:@"no active queue"]; return; }

    NSInteger firstAbs = self.queueMeta.count;
    [self.queueMeta addObjectsFromArray:items];
    AVPlayerItem *after = self.player.items.lastObject;
    NSInteger appended = 0;
    for (NSInteger i = 0; i < (NSInteger)items.count; i++) {
        AVPlayerItem *item = [self buildItemFrom:items[i] absIndex:firstAbs + i];
        if (item == nil) { continue; }
        [self.liveItems addObject:item];
        if ([self.player canInsertItem:item afterItem:after]) {
            [self.player insertItem:item afterItem:after];
            after = item;
            appended++;
        }
    }
    if (appended == 0) { [self fail:command msg:@"nothing appended"]; return; }
    [self ok:command];
}

- (void)play:(CDVInvokedUrlCommand*)command {
    self.shouldBePlaying = YES;
    [self configureSession];
    [self applyPlay];
    [self ok:command];
}

- (void)pause:(CDVInvokedUrlCommand*)command {
    [self pauseWithReason:@"user"];
    [self ok:command];
}

- (void)stop:(CDVInvokedUrlCommand*)command {
    self.shouldBePlaying = NO;
    self.pauseReason = nil;
    [self teardownPlayback];
    self.queueMeta = nil;
    [[MPNowPlayingInfoCenter defaultCenter] setNowPlayingInfo:nil];
    [self maybeEmitState];
    [self ok:command];
}

- (void)seekToItem:(CDVInvokedUrlCommand*)command {
    NSDictionary *opts = [command argumentAtIndex:0 withDefault:@{}];
    NSInteger index = [opts[@"index"] integerValue];
    double posMs = [opts[@"positionMs"] doubleValue];
    if (self.player == nil || self.queueMeta == nil) { [self fail:command msg:@"no active queue"]; return; }
    if (index < 0 || index >= (NSInteger)self.queueMeta.count) { [self fail:command msg:@"index out of range"]; return; }
    if (index == self.lastReportedIndex) {
        [self.player seekToTime:CMTimeMakeWithSeconds(posMs / 1000.0, NSEC_PER_SEC)];
        [self refreshNowPlayingPlayback];
    } else if (index > self.lastReportedIndex) {
        [self jumpForwardToAbs:index];
        if (posMs > 0) { [self.player seekToTime:CMTimeMakeWithSeconds(posMs / 1000.0, NSEC_PER_SEC)]; }
    } else {
        [self rebuildFromAbs:index positionMs:posMs];
    }
    [self ok:command];
}

- (void)setRate:(CDVInvokedUrlCommand*)command {
    float rate = [[command argumentAtIndex:0 withDefault:@1] floatValue];
    self.requestedRate = rate > 0 ? rate : 1.0f;
    if (self.player && self.player.rate != 0) {
        self.player.rate = self.requestedRate;
        [self refreshNowPlayingPlayback];
    }
    [self ok:command];
}

- (void)getState:(CDVInvokedUrlCommand*)command {
    NSMutableDictionary *r = [NSMutableDictionary dictionary];
    r[@"generation"] = @(self.generation);
    r[@"state"] = [self computeState];
    NSString *reason = [self computeReason];
    if (reason) { r[@"reason"] = reason; }
    r[@"index"] = @(self.lastReportedIndex);
    NSDictionary *meta = [self metaAtAbs:self.lastReportedIndex];
    r[@"id"] = meta[@"id"] ?: @"";
    r[@"positionMs"] = @([self positionMs]);
    r[@"durationMs"] = @([self durationMs]);
    r[@"rate"] = @(self.player ? self.player.rate : 0);
    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:r]
                                callbackId:command.callbackId];
}

#pragma mark - queue internals

- (NSArray<AVPlayerItem*> *)buildItemsFromAbs:(NSInteger)start {
    NSMutableArray<AVPlayerItem*> *arr = [NSMutableArray array];
    for (NSInteger i = start; i < (NSInteger)self.queueMeta.count; i++) {
        AVPlayerItem *item = [self buildItemFrom:self.queueMeta[i] absIndex:i];
        if (item != nil) { [arr addObject:item]; }
    }
    self.liveItems = arr;
    return arr;
}

- (AVPlayerItem *)buildItemFrom:(NSDictionary *)o absIndex:(NSInteger)i {
    NSURL *u = [self urlFromString:o[@"url"]];
    if (u == nil) { return nil; }
    AVPlayerItem *item = [AVPlayerItem playerItemWithURL:u];
    // High-quality time-stretch for speech: the default algorithm sounds thin and robotic
    // on voice at non-1x speeds; Spectral is bypassed at rate 1.0 so it costs nothing.
    item.audioTimePitchAlgorithm = AVAudioTimePitchAlgorithmSpectral;
    double clip = [[o objectForKey:@"clipEndMs"] doubleValue];
    if (clip > 0) {
        item.forwardPlaybackEndTime = CMTimeMakeWithSeconds(clip / 1000.0, NSEC_PER_SEC);
    }
    objc_setAssociatedObject(item, kAbsIndexKey, @(i), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [item addObserver:self forKeyPath:@"status" options:NSKeyValueObservingOptionNew context:kItemStatusCtx];
    return item;
}

- (NSInteger)absIndexOf:(AVPlayerItem *)item {
    NSNumber *n = objc_getAssociatedObject(item, kAbsIndexKey);
    return n != nil ? n.integerValue : -1;
}

- (NSDictionary *)metaAtAbs:(NSInteger)abs {
    if (self.queueMeta == nil || abs < 0 || abs >= (NSInteger)self.queueMeta.count) { return @{}; }
    return self.queueMeta[abs];
}

- (BOOL)isBoundaryAtAbs:(NSInteger)abs {
    NSDictionary *meta = [self metaAtAbs:abs];
    return meta[@"boundary"] == nil || [meta[@"boundary"] boolValue];
}

/** The single bookkeeping path for EVERY current-item change (auto-advance, manual
 *  advance, skip, rebuild). Idempotent: repeated calls for the same item no-op. */
- (void)syncAfterItemChange {
    if (self.player == nil || self.queueMeta == nil) { return; }
    AVPlayerItem *cur = self.player.currentItem;
    if (cur == nil) {
        self.shouldBePlaying = NO;
        [self endBufferKeepAlive];
        [self stopHeartbeat];
        [self emit:@"ended" payload:@{}];
        self.lastReportedIndex = -1;
        [[MPNowPlayingInfoCenter defaultCenter] setNowPlayingInfo:nil];
        [self maybeEmitState];
        return;
    }
    NSInteger abs = [self absIndexOf:cur];
    if (abs == self.lastReportedIndex) { return; }
    self.lastReportedIndex = abs;
    if (self.player.rate != 0 && fabsf(self.player.rate - self.requestedRate) > 0.01f) {
        self.player.rate = self.requestedRate;
    }
    [self refreshNowPlayingItem];
    NSDictionary *meta = [self metaAtAbs:abs];
    [self emit:@"transition" payload:@{ @"index": @(abs),
                                        @"id": meta[@"id"] ?: @"",
                                        @"tag": meta[@"tag"] ?: @"" }];
}

// A CLIPPED item (forwardPlaybackEndTime) fires DidPlayToEnd but does NOT auto-advance
// an AVQueuePlayer — advance manually. Non-clipped items auto-advance natively, in which
// case currentItem already moved on and this handler must not advance again.
- (void)itemDidEnd:(NSNotification*)n {
    dispatch_async(dispatch_get_main_queue(), ^{
        AVPlayerItem *item = (AVPlayerItem *)n.object;
        if (self.player == nil || ![self.liveItems containsObject:item]) { return; }
        if (self.player.currentItem == item) {
            [self.player advanceToNextItem];
            if (self.shouldBePlaying) { [self applyPlay]; }
        }
        [self syncAfterItemChange];
    });
}

// A queue item failed to stream (404, network drop): report and skip so background
// playback continues instead of stalling silently.
- (void)itemFailed:(NSNotification*)n {
    dispatch_async(dispatch_get_main_queue(), ^{
        AVPlayerItem *item = (AVPlayerItem *)n.object;
        if (self.player == nil || ![self.liveItems containsObject:item]) { return; }
        NSError *e = n.userInfo[AVPlayerItemFailedToPlayToEndTimeErrorKey];
        [self emitItemError:item code:@"queue_item_failed" message:e.localizedDescription];
        [self skipFailedItem:item];
    });
}

- (void)skipFailedItem:(AVPlayerItem *)item {
    if (self.player.currentItem == item) {
        [self.player advanceToNextItem];
        if (self.shouldBePlaying) { [self applyPlay]; }
        [self syncAfterItemChange];
    }
}

- (void)jumpForwardToAbs:(NSInteger)target {
    NSInteger guard = self.liveItems.count;
    while (guard-- > 0 && self.player.currentItem != nil && [self absIndexOf:self.player.currentItem] < target) {
        [self.player advanceToNextItem];
    }
    if (self.shouldBePlaying) { [self applyPlay]; }
    [self syncAfterItemChange];
}

- (void)rebuildFromAbs:(NSInteger)abs positionMs:(double)posMs {
    [self removeItemObservers];
    NSArray<AVPlayerItem*> *built = [self buildItemsFromAbs:abs];
    if (built.count == 0) { return; }
    self.lastReportedIndex = -1;
    [self.player removeAllItems];
    AVPlayerItem *after = nil;
    for (AVPlayerItem *item in built) {
        if ([self.player canInsertItem:item afterItem:after]) {
            [self.player insertItem:item afterItem:after];
            after = item;
        }
    }
    if (posMs > 0) {
        [self.player seekToTime:CMTimeMakeWithSeconds(posMs / 1000.0, NSEC_PER_SEC)];
    }
    if (self.shouldBePlaying) { [self applyPlay]; }
    [self syncAfterItemChange];
}

- (void)applyPlay {
    self.pauseReason = nil;
    self.player.rate = self.requestedRate;
    [self refreshNowPlayingPlayback];
}

- (void)pauseWithReason:(NSString *)reason {
    self.shouldBePlaying = NO;
    self.pauseReason = reason;
    [self endBufferKeepAlive];
    [self.player pause];
    [self refreshNowPlayingPlayback];
}

#pragma mark - remote commands

- (void)setupRemoteCommands {
    // Registered ONCE for the app lifetime — re-adding per queue would accumulate
    // duplicate handlers and a single lock-screen press would fire N times.
    if (self.remoteCommandsRegistered) { return; }
    self.remoteCommandsRegistered = YES;
    MPRemoteCommandCenter *c = [MPRemoteCommandCenter sharedCommandCenter];
    __weak NativeAudioPlayer *weakSelf = self;
    [c.playCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *e) {
        NativeAudioPlayer *s = weakSelf;
        s.shouldBePlaying = YES;
        [s configureSession];
        [s applyPlay];
        [s auditControl:@"play"];
        return MPRemoteCommandHandlerStatusSuccess;
    }];
    [c.pauseCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *e) {
        [weakSelf pauseWithReason:@"user"];
        [weakSelf auditControl:@"pause"];
        return MPRemoteCommandHandlerStatusSuccess;
    }];
    [c.nextTrackCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *e) {
        [weakSelf remoteNext];
        return MPRemoteCommandHandlerStatusSuccess;
    }];
    [c.previousTrackCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *e) {
        [weakSelf remotePrevious];
        return MPRemoteCommandHandlerStatusSuccess;
    }];
    c.nextTrackCommand.enabled = YES;
    c.previousTrackCommand.enabled = YES;
    [c.changePlaybackPositionCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *e) {
        MPChangePlaybackPositionCommandEvent *pe = (MPChangePlaybackPositionCommandEvent *)e;
        [weakSelf.player seekToTime:CMTimeMakeWithSeconds(pe.positionTime, NSEC_PER_SEC)];
        [weakSelf refreshNowPlayingPlayback];
        return MPRemoteCommandHandlerStatusSuccess;
    }];
}

- (void)remoteNext {
    if (self.queueMeta == nil || self.lastReportedIndex < 0) { return; }
    for (NSInteger i = self.lastReportedIndex + 1; i < (NSInteger)self.queueMeta.count; i++) {
        if ([self isBoundaryAtAbs:i]) {
            [self auditControl:@"next"];
            [self jumpForwardToAbs:i];
            return;
        }
    }
}

- (void)remotePrevious {
    if (self.queueMeta == nil || self.lastReportedIndex < 0) { return; }
    NSInteger verseStart = self.lastReportedIndex;
    while (verseStart > 0 && ![self isBoundaryAtAbs:verseStart]) { verseStart--; }
    NSInteger target = verseStart;
    for (NSInteger i = verseStart - 1; i >= 0; i--) {
        if ([self isBoundaryAtAbs:i]) { target = i; break; }
    }
    [self auditControl:@"previous"];
    if (target == self.lastReportedIndex) {
        [self.player seekToTime:kCMTimeZero];
        [self refreshNowPlayingPlayback];
    } else {
        [self rebuildFromAbs:target positionMs:0];
    }
}

#pragma mark - session / interruptions

- (void)configureSession {
    if (!self.sessionObserversRegistered) {
        self.sessionObserversRegistered = YES;
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(sessionInterrupted:)
                                                     name:AVAudioSessionInterruptionNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(routeChanged:)
                                                     name:AVAudioSessionRouteChangeNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(appEnteredBackground:)
                                                     name:UIApplicationDidEnterBackgroundNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(playbackStalled:)
                                                     name:AVPlayerItemPlaybackStalledNotification
                                                   object:nil];
    }
    // Force Playback + Default mode with the full 3-arg form: the shared session may be
    // left in PlayAndRecord / VoiceChat by the microphone, the TTS engine or the WebView,
    // which routes audio to the earpiece with narrowband voice processing.
    AVAudioSession *s = [AVAudioSession sharedInstance];
    [s setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeDefault options:0 error:nil];
    [s setActive:YES error:nil];
    [self setupRemoteCommands];
}

// The ONE interruption path: Began pauses and reports; Ended auto-resumes only when the
// system says shouldResume and nothing else paused us in between.
- (void)sessionInterrupted:(NSNotification*)n {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSUInteger type = [n.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];
        if (type == AVAudioSessionInterruptionTypeBegan) {
            if (self.player == nil || self.player.currentItem == nil) { return; }
            self.pauseReason = @"interruption";
            [self.player pause];
            [self maybeEmitState];
            [self auditLog:@"interruptionBegan" json:@"{}"];
            return;
        }
        NSUInteger opts = [n.userInfo[AVAudioSessionInterruptionOptionKey] unsignedIntegerValue];
        BOOL resume = (opts & AVAudioSessionInterruptionOptionShouldResume) != 0
            && self.shouldBePlaying
            && [@"interruption" isEqualToString:self.pauseReason];
        if (resume) {
            AVAudioSession *s = [AVAudioSession sharedInstance];
            [s setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeDefault options:0 error:nil];
            [s setActive:YES error:nil];
            [self applyPlay];
        }
        [self auditLog:@"interruptionEnded" json:[NSString stringWithFormat:@"{\"resumed\":%@}", resume ? @"true" : @"false"]];
    });
}

- (void)routeChanged:(NSNotification*)n {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSUInteger reason = [n.userInfo[AVAudioSessionRouteChangeReasonKey] unsignedIntegerValue];
        if (reason != AVAudioSessionRouteChangeReasonOldDeviceUnavailable) { return; }
        if (self.player == nil || self.player.rate == 0) { return; }
        [self pauseWithReason:@"noisy"];
        [self maybeEmitState];
    });
}

// WKWebView flips the shared AVAudioSession at background entry even when it plays no
// audio, which makes iOS pause the player (rate drops to 0 with no interruption
// notification). Re-assert the session and resume immediately while we still have
// runtime; the stall kick covers any later recurrence through the same single path.
- (void)appEnteredBackground:(NSNotification*)n {
    if (!self.shouldBePlaying || self.player == nil) { return; }
    [self reassertSession];
    if (self.player.rate == 0 && self.pauseReason == nil && self.player.currentItem != nil) {
        self.player.rate = self.requestedRate;
    }
    if (self.player.timeControlStatus != AVPlayerTimeControlStatusPlaying) { [self beginBufferKeepAlive]; }
}

- (void)reassertSession {
    AVAudioSession *s = [AVAudioSession sharedInstance];
    [s setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeDefault options:0 error:nil];
    [s setActive:YES error:nil];
}

- (void)playbackStalled:(NSNotification*)n {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.shouldBePlaying || self.player == nil) { return; }
        if (![self.liveItems containsObject:(AVPlayerItem *)n.object]) { return; }
        [self beginBufferKeepAlive];
    });
}

// An intentionally playing player must never park on Paused (waits=YES buffers on
// Waiting instead). The kick is DELAYED and re-verified: a real interruption silences
// the player BEFORE its notification arrives, so an immediate kick would resume audio
// mid-phone-call. After the delay the interruption reason is already set and aborts it.
- (void)scheduleStallKick {
    long long token = ++self.stallToken;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.7 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (token != self.stallToken || self.player == nil) { return; }
        BOOL stillStalled = self.shouldBePlaying && self.pauseReason == nil
            && self.player.currentItem != nil
            && self.player.timeControlStatus == AVPlayerTimeControlStatusPaused;
        if (stillStalled) {
            [self auditLog:@"stallKick" json:@"{}"];
            [self reassertSession];
            self.player.rate = self.requestedRate;
        }
    });
}

// Keeps the process alive while AVPlayer buffers silently in the background: with no
// audio playing iOS suspends the app within seconds, freezing the download forever.
- (void)beginBufferKeepAlive {
    if (self.bufferKeepAlive != UIBackgroundTaskInvalid) { return; }
    __weak NativeAudioPlayer *weakSelf = self;
    self.bufferKeepAlive = [[UIApplication sharedApplication]
        beginBackgroundTaskWithName:@"audio-buffering"
                  expirationHandler:^{ [weakSelf endBufferKeepAlive]; }];
}

- (void)endBufferKeepAlive {
    if (self.bufferKeepAlive == UIBackgroundTaskInvalid) { return; }
    [[UIApplication sharedApplication] endBackgroundTask:self.bufferKeepAlive];
    self.bufferKeepAlive = UIBackgroundTaskInvalid;
}

#pragma mark - state & events

- (NSString *)computeState {
    if (self.player == nil || self.player.currentItem == nil) { return @"idle"; }
    switch (self.player.timeControlStatus) {
        case AVPlayerTimeControlStatusPlaying: return @"playing";
        case AVPlayerTimeControlStatusWaitingToPlayAtSpecifiedRate: return @"buffering";
        default: return @"paused";
    }
}

- (NSString *)computeReason {
    if (![[self computeState] isEqualToString:@"paused"]) { return nil; }
    return self.pauseReason ?: @"user";
}

/** Emits a state event only when the normalized (state, reason) tuple changed. */
- (void)maybeEmitState {
    NSString *state = [self computeState];
    NSString *reason = [self computeReason];
    BOOL sameState = [state isEqualToString:self.lastState ?: @""];
    BOOL sameReason = (reason == nil && self.lastReason == nil) || [reason isEqualToString:self.lastReason ?: @""];
    if (sameState && sameReason) { return; }
    self.lastState = state;
    self.lastReason = reason;
    NSMutableDictionary *p = [NSMutableDictionary dictionary];
    p[@"state"] = state;
    if (reason) { p[@"reason"] = reason; }
    p[@"index"] = @(self.lastReportedIndex);
    p[@"positionMs"] = @([self positionMs]);
    p[@"rate"] = @(self.player ? self.player.rate : 0);
    [self emit:@"state" payload:p];
}

- (void)emitItemError:(AVPlayerItem *)item code:(NSString *)code message:(NSString *)message {
    [self emit:@"error" payload:@{ @"code": code,
                                   @"message": message ?: @"playback error",
                                   @"index": @([self absIndexOf:item]) }];
}

- (void)emit:(NSString*)type payload:(NSDictionary*)payload {
    NSMutableDictionary *o = [payload mutableCopy] ?: [NSMutableDictionary dictionary];
    o[@"type"] = type;
    o[@"generation"] = @(self.generation);
    o[@"seq"] = @(++self.seq);
    if (napAudit()) {
        NSData *d = [NSJSONSerialization dataWithJSONObject:o options:0 error:nil];
        NSLog(@"[AUD] %@ %@", type, d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : @"{}");
    }
    if (self.eventsCallbackId == nil) { return; }
    CDVPluginResult *r = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:o];
    [r setKeepCallbackAsBool:YES];
    [self.commandDelegate sendPluginResult:r callbackId:self.eventsCallbackId];
}

- (void)auditControl:(NSString *)action {
    [self auditLog:@"control" json:[NSString stringWithFormat:@"{\"action\":\"%@\",\"origin\":\"notif\"}", action]];
}

- (void)auditLog:(NSString *)ev json:(NSString *)json {
    if (napAudit()) { NSLog(@"[AUD] %@ %@", ev, json); }
}

#pragma mark - KVO

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (context == kCurrentItemCtx) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self syncAfterItemChange]; });
        return;
    }
    if (context == kTimeControlCtx) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.player == nil) { return; }
            if (self.player.timeControlStatus == AVPlayerTimeControlStatusPlaying) {
                [self endBufferKeepAlive];
            } else if (self.shouldBePlaying) {
                [self beginBufferKeepAlive];
                if (self.player.timeControlStatus == AVPlayerTimeControlStatusPaused) {
                    [self scheduleStallKick];
                }
            }
            [self maybeEmitState];
            [self refreshNowPlayingPlayback];
        });
        return;
    }
    if (context == kItemStatusCtx) {
        dispatch_async(dispatch_get_main_queue(), ^{
            AVPlayerItem *item = (AVPlayerItem *)object;
            if (item.status != AVPlayerItemStatusFailed || ![self.liveItems containsObject:item]) { return; }
            [self emitItemError:item code:@"queue_item_failed" message:item.error.localizedDescription];
            [self skipFailedItem:item];
        });
        return;
    }
    [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
}

#pragma mark - Now Playing

- (void)refreshNowPlayingItem {
    NSDictionary *meta = [self metaAtAbs:self.lastReportedIndex][@"metadata"] ?: @{};
    self.nowPlaying = [NSMutableDictionary dictionary];
    if (meta[@"title"]) { self.nowPlaying[MPMediaItemPropertyTitle] = meta[@"title"]; }
    if (meta[@"artist"]) { self.nowPlaying[MPMediaItemPropertyArtist] = meta[@"artist"]; }
    if (meta[@"album"]) { self.nowPlaying[MPMediaItemPropertyAlbumTitle] = meta[@"album"]; }
    self.nowPlaying[MPMediaItemPropertyPlaybackDuration] = @([self durationMs] / 1000.0);
    self.nowPlaying[MPNowPlayingInfoPropertyElapsedPlaybackTime] = @([self positionMs] / 1000.0);
    self.nowPlaying[MPNowPlayingInfoPropertyPlaybackRate] = @(self.player.rate);
    [self applyArtwork:meta[@"artworkUrl"]];
    [[MPNowPlayingInfoCenter defaultCenter] setNowPlayingInfo:self.nowPlaying];
}

/** Rate/elapsed refresh on play / pause / seek / rate change — never periodic; the OS
 *  interpolates the lock-screen progress bar from (elapsed, rate) itself. */
- (void)refreshNowPlayingPlayback {
    if (self.nowPlaying == nil) { return; }
    self.nowPlaying[MPNowPlayingInfoPropertyElapsedPlaybackTime] = @([self positionMs] / 1000.0);
    self.nowPlaying[MPNowPlayingInfoPropertyPlaybackRate] = @(self.player ? self.player.rate : 0);
    [[MPNowPlayingInfoCenter defaultCenter] setNowPlayingInfo:self.nowPlaying];
}

- (void)applyArtwork:(NSString *)url {
    if (url.length == 0) { return; }
    if ([url isEqualToString:self.artworkUrl] && self.artwork != nil) {
        self.nowPlaying[MPMediaItemPropertyArtwork] = self.artwork;
        return;
    }
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSURL *u = [self urlFromString:url];
        NSData *data = u ? [NSData dataWithContentsOfURL:u] : nil;
        UIImage *img = data ? [UIImage imageWithData:data] : nil;
        if (img == nil) { return; }
        dispatch_async(dispatch_get_main_queue(), ^{
            self.artworkUrl = url;
            self.artwork = [[MPMediaItemArtwork alloc] initWithBoundsSize:img.size
                                                           requestHandler:^UIImage * _Nonnull(CGSize size) { return img; }];
            if (self.nowPlaying != nil) {
                self.nowPlaying[MPMediaItemPropertyArtwork] = self.artwork;
                [[MPNowPlayingInfoCenter defaultCenter] setNowPlayingInfo:self.nowPlaying];
            }
        });
    });
}

#pragma mark - heartbeat (harness audit)

- (void)startHeartbeat {
    if (!napAudit()) { return; }
    [self stopHeartbeat];
    self.heartbeat = [NSTimer scheduledTimerWithTimeInterval:15.0 repeats:YES block:^(NSTimer *t) {
        NativeAudioPlayer *s = self;
        if (s.player == nil) { return; }
        NSDictionary *meta = [s metaAtAbs:s.lastReportedIndex];
        NSLog(@"[AUD] hb {\"pos\":%.0f,\"qIdx\":%ld,\"id\":\"%@\",\"playing\":%@,\"rate\":%.2f}",
              [s positionMs], (long)s.lastReportedIndex, meta[@"id"] ?: @"",
              s.player.rate != 0 ? @"true" : @"false", s.player.rate);
    }];
}

- (void)stopHeartbeat {
    if (self.heartbeat) { [self.heartbeat invalidate]; self.heartbeat = nil; }
}

#pragma mark - TTS synthesis

- (void)audit:(CDVInvokedUrlCommand*)command {
    NSString *line = [command argumentAtIndex:0 withDefault:@""];
    if (napAudit()) { NSLog(@"[AUD] %@", line); }
    [self ok:command];
}

- (void)getVoices:(CDVInvokedUrlCommand*)command {
    NSMutableArray *arr = [NSMutableArray array];
    for (AVSpeechSynthesisVoice *v in [AVSpeechSynthesisVoice speechVoices]) {
        [arr addObject:@{ @"id": v.identifier,
                          @"name": v.name,
                          @"locale": v.language,
                          @"quality": @(v.quality),
                          @"requiresNetwork": @NO }];
    }
    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsArray:arr]
                                callbackId:command.callbackId];
}

- (void)synthesizeToFile:(CDVInvokedUrlCommand*)command {
    NSDictionary *opts = [command argumentAtIndex:0 withDefault:@{}];
    NSString *text = opts[@"text"];
    NSString *voiceId = opts[@"voiceId"];
    NSString *utteranceId = opts[@"utteranceId"];
    if (text.length == 0 || utteranceId.length == 0) { [self fail:command msg:@"missing text or utteranceId"]; return; }

    NSString *dir = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject
                     stringByAppendingPathComponent:@"tts-cache"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *caf = [dir stringByAppendingPathComponent:[utteranceId stringByAppendingPathExtension:@"caf"]];
    NSString *sidecar = [dir stringByAppendingPathComponent:[utteranceId stringByAppendingPathExtension:@"json"]];

    NSDictionary *cached = [self readSidecar:sidecar cafPath:caf];
    if (cached != nil) {
        [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:cached]
                                    callbackId:command.callbackId];
        return;
    }

    AVSpeechSynthesisVoice *voice = voiceId.length > 0 ? [AVSpeechSynthesisVoice voiceWithIdentifier:voiceId] : nil;
    if (voice == nil && voiceId.length > 0) { [self fail:command msg:[@"voice not found: " stringByAppendingString:voiceId]]; return; }

    AVSpeechUtterance *utterance = [AVSpeechUtterance speechUtteranceWithString:text];
    utterance.rate = AVSpeechUtteranceDefaultSpeechRate;
    if (voice) { utterance.voice = voice; }

    NAPSynthJob *job = [NAPSynthJob new];
    job.synth = [AVSpeechSynthesizer new];
    job.synth.delegate = self;
    job.timestamps = [NSMutableArray array];
    job.callbackId = command.callbackId;
    job.cafPath = caf;
    job.sidecarPath = sidecar;
    [self.synthJobs setObject:job forKey:utterance];

    __weak NativeAudioPlayer *weakSelf = self;
    [job.synth writeUtterance:utterance toBufferCallback:^(AVAudioBuffer *buffer) {
        dispatch_async(weakSelf.synthQueue, ^{
            NativeAudioPlayer *s = weakSelf;
            if (s == nil || job.finished) { return; }
            AVAudioPCMBuffer *pcm = [buffer isKindOfClass:[AVAudioPCMBuffer class]] ? (AVAudioPCMBuffer *)buffer : nil;
            if (pcm == nil || pcm.frameLength == 0) {
                [s finalizeSynthJob:job utterance:utterance];
                return;
            }
            NSError *err = nil;
            if (job.file == nil) {
                job.sampleRate = pcm.format.sampleRate;
                job.file = [[AVAudioFile alloc] initForWriting:[NSURL fileURLWithPath:job.cafPath]
                                                      settings:pcm.format.settings error:&err];
            }
            if (err == nil && job.file != nil) {
                [job.file writeFromBuffer:pcm error:&err];
            }
            if (err != nil) {
                [s failSynthJob:job utterance:utterance message:err.localizedDescription];
                return;
            }
            job.frames += pcm.frameLength;
        });
    }];
}

- (void)speechSynthesizer:(AVSpeechSynthesizer *)synthesizer willSpeakRangeOfSpeechString:(NSRange)characterRange utterance:(AVSpeechUtterance *)utterance {
    dispatch_async(self.synthQueue, ^{
        NAPSynthJob *job = [self.synthJobs objectForKey:utterance];
        if (job == nil || job.finished) { return; }
        double ms = job.sampleRate > 0 ? job.frames / job.sampleRate * 1000.0 : 0;
        [job.timestamps addObject:@{ @"charStart": @(characterRange.location),
                                     @"charEnd": @(characterRange.location + characterRange.length),
                                     @"startMs": @(ms) }];
    });
}

- (void)speechSynthesizer:(AVSpeechSynthesizer *)synthesizer didFinishSpeechUtterance:(AVSpeechUtterance *)utterance {
    dispatch_async(self.synthQueue, ^{
        NAPSynthJob *job = [self.synthJobs objectForKey:utterance];
        if (job != nil) { [self finalizeSynthJob:job utterance:utterance]; }
    });
}

- (void)speechSynthesizer:(AVSpeechSynthesizer *)synthesizer didCancelSpeechUtterance:(AVSpeechUtterance *)utterance {
    dispatch_async(self.synthQueue, ^{
        NAPSynthJob *job = [self.synthJobs objectForKey:utterance];
        if (job != nil) { [self failSynthJob:job utterance:utterance message:@"synthesis canceled"]; }
    });
}

- (void)finalizeSynthJob:(NAPSynthJob *)job utterance:(AVSpeechUtterance *)utterance {
    if (job.finished) { return; }
    job.finished = YES;
    job.file = nil;
    double durationMs = job.sampleRate > 0 ? job.frames / job.sampleRate * 1000.0 : 0;
    if (durationMs <= 0) {
        [[NSFileManager defaultManager] removeItemAtPath:job.cafPath error:nil];
        [self sendSynthError:job message:@"synthesized file invalid"];
        return;
    }
    NSDictionary *result = @{ @"fileUrl": [[NSURL fileURLWithPath:job.cafPath] absoluteString],
                              @"durationMs": @(durationMs),
                              @"wordTimestamps": [job.timestamps copy] };
    NSDictionary *sidecar = @{ @"durationMs": @(durationMs), @"wordTimestamps": [job.timestamps copy] };
    NSData *d = [NSJSONSerialization dataWithJSONObject:sidecar options:0 error:nil];
    [d writeToFile:job.sidecarPath atomically:YES];
    [self.synthJobs removeObjectForKey:utterance];
    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:result]
                                callbackId:job.callbackId];
}

- (void)failSynthJob:(NAPSynthJob *)job utterance:(AVSpeechUtterance *)utterance message:(NSString *)message {
    if (job.finished) { return; }
    job.finished = YES;
    job.file = nil;
    [[NSFileManager defaultManager] removeItemAtPath:job.cafPath error:nil];
    [self.synthJobs removeObjectForKey:utterance];
    [self sendSynthError:job message:message];
}

- (void)sendSynthError:(NAPSynthJob *)job message:(NSString *)message {
    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:message]
                                callbackId:job.callbackId];
}

- (NSDictionary *)readSidecar:(NSString *)sidecarPath cafPath:(NSString *)cafPath {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:sidecarPath] || ![fm fileExistsAtPath:cafPath]) { return nil; }
    NSData *d = [NSData dataWithContentsOfFile:sidecarPath];
    NSDictionary *o = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    if (![o isKindOfClass:[NSDictionary class]]) { return nil; }
    NSMutableDictionary *r = [o mutableCopy];
    r[@"fileUrl"] = [[NSURL fileURLWithPath:cafPath] absoluteString];
    return r;
}

#pragma mark - helpers

/** Parse a URL string, percent-encoding as a fallback (raw Hebrew/space paths crash AVPlayerItem).
 *  WebView-relative urls (bundled app assets) resolve into the packaged www folder. */
- (NSURL *)urlFromString:(NSString *)url {
    if (url.length == 0) { return nil; }
    if (![url containsString:@"://"]) {
        NSString *wwwPath = [[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:@"www"];
        return [NSURL fileURLWithPath:[wwwPath stringByAppendingPathComponent:url]];
    }
    NSURL *u = [NSURL URLWithString:url];
    if (u == nil) {
        NSString *enc = [url stringByAddingPercentEncodingWithAllowedCharacters:
                         [NSCharacterSet URLQueryAllowedCharacterSet]];
        u = enc ? [NSURL URLWithString:enc] : nil;
    }
    return u;
}

- (double)positionMs {
    if (self.player == nil) { return 0; }
    double s = CMTimeGetSeconds(self.player.currentTime);
    return isnan(s) ? 0 : s * 1000.0;
}

- (double)durationMs {
    AVPlayerItem *cur = self.player.currentItem;
    if (cur == nil) { return 0; }
    CMTime f = cur.forwardPlaybackEndTime;
    if (CMTIME_IS_VALID(f)) {
        double fs = CMTimeGetSeconds(f);
        if (fs > 0) { return fs * 1000.0; }
    }
    double d = CMTimeGetSeconds(cur.duration);
    return isnan(d) ? 0 : d * 1000.0;
}

- (void)removeItemObservers {
    for (AVPlayerItem *item in self.liveItems) {
        @try { [item removeObserver:self forKeyPath:@"status" context:kItemStatusCtx]; } @catch (NSException *ex) {}
    }
    self.liveItems = nil;
}

- (void)teardownPlayback {
    [self stopHeartbeat];
    [self removeItemObservers];
    self.lastReportedIndex = -1;
    if (self.player) {
        @try { [self.player removeObserver:self forKeyPath:@"currentItem" context:kCurrentItemCtx]; } @catch (NSException *ex) {}
        @try { [self.player removeObserver:self forKeyPath:@"timeControlStatus" context:kTimeControlCtx]; } @catch (NSException *ex) {}
        [self.player pause];
        self.player = nil;
    }
    [self endBufferKeepAlive];
}

- (void)ok:(CDVInvokedUrlCommand*)command {
    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK]
                                callbackId:command.callbackId];
}

- (void)fail:(CDVInvokedUrlCommand*)command msg:(NSString*)msg {
    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:msg]
                                callbackId:command.callbackId];
}

@end
