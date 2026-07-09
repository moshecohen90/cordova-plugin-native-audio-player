#import "NativeAudioPlayer.h"
#import <AVFoundation/AVFoundation.h>
#import <MediaPlayer/MediaPlayer.h>

/**
 * iOS side: AVPlayer for playback + MPNowPlayingInfoCenter / MPRemoteCommandCenter for the
 * native Now Playing card (lock screen + Control Center), the same UI Apple Music / Podcasts
 * use. UIBackgroundModes:audio (added by plugin.xml) keeps it playing in the background.
 */
@interface NativeAudioPlayer ()
@property (nonatomic, strong) AVPlayer *player;
@property (nonatomic, strong) id timeObserver;
@property (nonatomic, copy) NSString *eventsCallbackId;
@property (nonatomic, strong) NSMutableDictionary *nowPlaying;
@property (nonatomic) double clipDurationMs;
// Seekbar length to REPORT without clipping (single-verse mode: the MP3's own duration
// includes bogus trailing silence, but clipping would freeze the position at the boundary).
@property (nonatomic) double displayDurationMs;
@property (nonatomic) BOOL remoteCommandsRegistered;
@property (nonatomic) BOOL looping;
@property (nonatomic, strong) AVPlayerItem *observedItem;
@property (nonatomic) BOOL interruptionRegistered;
// Native queue (background verse-to-verse continuity with zero JS).
@property (nonatomic, strong) NSMutableArray<NSDictionary*> *queueMeta;   // FULL caller array
@property (nonatomic, strong) NSMutableArray<NSNumber*> *queueAbsIndex;   // player order -> abs index
@property (nonatomic, strong) NSMutableArray<AVPlayerItem*> *queueItems;  // observed player items
@property (nonatomic) NSInteger queueIndex;                               // position in player order
@property (nonatomic) BOOL queueActive;
@end

@implementation NativeAudioPlayer

- (void)startEvents:(CDVInvokedUrlCommand*)command {
    self.eventsCallbackId = command.callbackId;
    CDVPluginResult *r = [CDVPluginResult resultWithStatus:CDVCommandStatus_NO_RESULT];
    [r setKeepCallbackAsBool:YES];
    [self.commandDelegate sendPluginResult:r callbackId:command.callbackId];
}

- (void)load:(CDVInvokedUrlCommand*)command {
    NSDictionary *opts = [command argumentAtIndex:0 withDefault:@{}];
    NSString *url = opts[@"url"];
    if (url == nil || url.length == 0) { [self fail:command msg:@"missing url"]; return; }

    NSLog(@"[NativeAudioPlayer] load url=%@ title=%@", url, opts[@"title"]);
    NSURL *u = [self urlFromString:url];
    if (u == nil) { [self fail:command msg:@"invalid url"]; return; }
    [self configureSession];
    [self teardownPlayer];
    self.looping = NO;

    AVPlayerItem *item = [AVPlayerItem playerItemWithURL:u];
    // High-quality time-stretch for speech. AVPlayer's default (TimeDomain / low-quality)
    // sounds thin and robotic on voice at non-1x speeds, whereas Android's ExoPlayer uses the
    // high-quality Sonic algorithm by default — which is why the same verse MP3 sounds good on
    // Android but bad on iOS. Spectral is the best-quality algorithm and is bypassed at rate 1.0.
    item.audioTimePitchAlgorithm = AVAudioTimePitchAlgorithmSpectral;
    // Clip to the real speech length so the Now Playing seekbar/duration is correct
    // (the MP3's own duration is unreliable) and playback ends without trailing silence.
    self.clipDurationMs = [[opts objectForKey:@"durationMs"] doubleValue];
    if (self.clipDurationMs > 0) {
        item.forwardPlaybackEndTime = CMTimeMakeWithSeconds(self.clipDurationMs / 1000.0, NSEC_PER_SEC);
    }
    self.displayDurationMs = [[opts objectForKey:@"displayDurationMs"] doubleValue];
    self.player = [AVPlayer playerWithPlayerItem:item];
    [self setupTimeObserver];
    [self setupRemoteCommands];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(itemDidEnd:)
                                                 name:AVPlayerItemDidPlayToEndTimeNotification
                                               object:item];
    // Surface load/decode failures to JS — without this a bad source (404 MP3 etc.)
    // leaves the app's verse promise pending forever and playback freezes.
    [item addObserver:self forKeyPath:@"status" options:NSKeyValueObservingOptionNew context:nil];
    self.observedItem = item;
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(itemFailed:)
                                                 name:AVPlayerItemFailedToPlayToEndTimeNotification
                                               object:item];

    BOOL autoplay = opts[@"autoplay"] ? [opts[@"autoplay"] boolValue] : YES;
    if (autoplay) { [self.player play]; }
    // Set Now Playing AFTER starting so the OS sees a non-zero playback rate and
    // designates us the active Now Playing app (needed for the Control Center card).
    [self updateNowPlayingInfo:opts];
    [self updateNowPlayingElapsed];
    [self emitState];
    [self ok:command];
}

// Native playlist via AVQueuePlayer: verse-to-verse advancing happens entirely in the OS,
// so playback continues in the background even when the WebView's JS is frozen.
- (void)setQueue:(CDVInvokedUrlCommand*)command {
    NSArray *items = [command argumentAtIndex:0 withDefault:@[]];
    NSInteger start = [[command argumentAtIndex:1 withDefault:@0] integerValue];
    double startPosMs = [[command argumentAtIndex:2 withDefault:@0] doubleValue];
    if (items.count == 0) { [self fail:command msg:@"empty queue"]; return; }
    if (start < 0 || start >= (NSInteger)items.count) { start = 0; }

    [self configureSession];
    [self teardownPlayer];
    self.looping = NO;
    self.clipDurationMs = 0;
    self.queueMeta = [items mutableCopy];       // FULL array: transition indices stay
    self.queueAbsIndex = [NSMutableArray array]; // absolute (matching Android + the JS contract)
    self.queueItems = [NSMutableArray array];

    NSMutableArray<AVPlayerItem*> *playerItems = [NSMutableArray array];
    for (NSInteger i = start; i < (NSInteger)items.count; i++) {
        NSDictionary *o = items[i];
        NSURL *u = [self urlFromString:o[@"url"]];
        if (u == nil) { continue; }
        AVPlayerItem *item = [AVPlayerItem playerItemWithURL:u];
        item.audioTimePitchAlgorithm = AVAudioTimePitchAlgorithmSpectral;
        double dur = [[o objectForKey:@"durationMs"] doubleValue];
        if (dur > 0) {
            // Clip each verse to its real speech length (the MP3 duration is unreliable).
            item.forwardPlaybackEndTime = CMTimeMakeWithSeconds(dur / 1000.0, NSEC_PER_SEC);
        }
        [playerItems addObject:item];
        [self.queueAbsIndex addObject:@(i)];
        [self.queueItems addObject:item];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(queueItemDidEnd:)
                                                     name:AVPlayerItemDidPlayToEndTimeNotification
                                                   object:item];
        // Surface stream failures (404 / network drop): without this the queue stalls
        // silently forever with a frozen Now Playing card.
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(queueItemFailed:)
                                                     name:AVPlayerItemFailedToPlayToEndTimeNotification
                                                   object:item];
        [item addObserver:self forKeyPath:@"status" options:NSKeyValueObservingOptionNew context:nil];
    }
    if (playerItems.count == 0) { [self fail:command msg:@"no valid items"]; return; }

    self.queueIndex = 0;
    self.queueActive = YES;
    self.player = [AVQueuePlayer queuePlayerWithItems:playerItems];
    [self setupTimeObserver];
    [self setupRemoteCommands];
    if (startPosMs > 0) {
        [self.player seekToTime:CMTimeMakeWithSeconds(startPosMs / 1000.0, NSEC_PER_SEC)];
    }
    [self.player play];
    [self updateNowPlayingInfo:[self currentQueueMeta]];
    [self updateNowPlayingElapsed];
    [self emitState];
    [self ok:command];
}

/** Meta of the currently playing queue item (player order -> absolute index). */
- (NSDictionary *)currentQueueMeta {
    if (!self.queueActive || self.queueIndex >= (NSInteger)self.queueAbsIndex.count) { return @{}; }
    NSInteger abs = [self.queueAbsIndex[self.queueIndex] integerValue];
    return abs < (NSInteger)self.queueMeta.count ? self.queueMeta[abs] : @{};
}

/** Parse a URL string, percent-encoding as a fallback (raw Hebrew/space paths crash AVPlayerItem). */
- (NSURL *)urlFromString:(NSString *)url {
    if (url.length == 0) { return nil; }
    NSURL *u = [NSURL URLWithString:url];
    if (u == nil) {
        NSString *enc = [url stringByAddingPercentEncodingWithAllowedCharacters:
                         [NSCharacterSet URLQueryAllowedCharacterSet]];
        u = enc ? [NSURL URLWithString:enc] : nil;
    }
    return u;
}

// A queue item played to its (clipped) end: AVQueuePlayer advances itself; we track the
// index, refresh the Now Playing card, and tell JS (which may be frozen — that's fine).
- (void)queueItemDidEnd:(NSNotification*)n {
    if (!self.queueActive) { return; }
    [self queueMovedForward];
}

- (void)queueMovedForward {
    self.queueIndex++;
    if (self.queueIndex >= (NSInteger)self.queueAbsIndex.count) {
        self.queueActive = NO;
        [self emit:@"ended" payload:@{ @"queue": @YES }];
        return;
    }
    NSInteger abs = [self.queueAbsIndex[self.queueIndex] integerValue];
    NSDictionary *meta = [self currentQueueMeta];
    [self updateNowPlayingInfo:meta];
    [self updateNowPlayingElapsed];
    // Absolute index into the caller's original array (same contract as Android).
    [self emit:@"transition" payload:@{ @"index": @(abs),
                                        @"id": (meta[@"id"] ?: @"") }];
}

// A queue item failed to stream (404, network drop): report it and skip to the next
// item so background playback continues instead of stalling silently forever.
- (void)queueItemFailed:(NSNotification*)n {
    NSError *e = n.userInfo[AVPlayerItemFailedToPlayToEndTimeErrorKey];
    [self emit:@"error" payload:@{ @"code": @"queue_item_failed",
                                   @"message": e.localizedDescription ?: @"queue item failed" }];
    [self queueSkipFailedItem];
}

- (void)queueSkipFailedItem {
    if (!self.queueActive || ![self.player isKindOfClass:[AVQueuePlayer class]]) { return; }
    [(AVQueuePlayer *)self.player advanceToNextItem];
    [self.player play];
    [self queueMovedForward];
}

// Play the bundled silent clip on loop so the Now Playing card shows during TTS (which
// produces no native track of its own). We loop it in itemDidEnd: so the audio session
// stays active and the transport controls (which route to the app) stay live.
- (void)playSilentLoop:(CDVInvokedUrlCommand*)command {
    NSDictionary *opts = [command argumentAtIndex:0 withDefault:@{}];
    NSString *path = [[NSBundle mainBundle] pathForResource:@"silence" ofType:@"mp3"];
    if (path == nil) { [self fail:command msg:@"silence asset missing"]; return; }

    [self configureSession];
    [self teardownPlayer];
    self.looping = YES;
    self.clipDurationMs = 0;

    AVPlayerItem *item = [AVPlayerItem playerItemWithURL:[NSURL fileURLWithPath:path]];
    self.player = [AVPlayer playerWithPlayerItem:item];
    self.player.actionAtItemEnd = AVPlayerActionAtItemEndNone; // we re-seek on end ourselves
    [self setupTimeObserver];
    [self setupRemoteCommands];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(itemDidEnd:)
                                                 name:AVPlayerItemDidPlayToEndTimeNotification
                                               object:item];

    [self.player play];
    [self updateNowPlayingInfo:opts];
    [self updateNowPlayingElapsed];
    [self emitState];
    [self ok:command];
}

- (void)play:(CDVInvokedUrlCommand*)command {
    if (self.player) { [self.player play]; [self emitState]; }
    [self ok:command];
}

- (void)pause:(CDVInvokedUrlCommand*)command {
    if (self.player) { [self.player pause]; [self emitState]; }
    [self ok:command];
}

- (void)stop:(CDVInvokedUrlCommand*)command {
    self.looping = NO;
    [self teardownPlayer];
    [[MPNowPlayingInfoCenter defaultCenter] setNowPlayingInfo:nil];
    [self ok:command];
}

- (void)seekTo:(CDVInvokedUrlCommand*)command {
    double ms = [[command argumentAtIndex:0 withDefault:@0] doubleValue];
    if (self.player) {
        [self.player seekToTime:CMTimeMakeWithSeconds(ms / 1000.0, NSEC_PER_SEC)];
        [self updateNowPlayingElapsed];
    }
    [self ok:command];
}

- (void)setRate:(CDVInvokedUrlCommand*)command {
    float rate = [[command argumentAtIndex:0 withDefault:@1] floatValue];
    if (self.player && self.player.rate != 0) { self.player.rate = rate; }
    [self ok:command];
}

- (void)updateMetadata:(CDVInvokedUrlCommand*)command {
    NSDictionary *opts = [command argumentAtIndex:0 withDefault:@{}];
    [self updateNowPlayingInfo:opts];
    [self ok:command];
}

- (void)getPosition:(CDVInvokedUrlCommand*)command {
    NSDictionary *r = @{ @"positionMs": @([self positionMs]), @"durationMs": @([self durationMs]) };
    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:r]
                                callbackId:command.callbackId];
}

#pragma mark - internals

- (void)configureSession {
    // Phone calls / Siri pause AVPlayer without any callback to the app — tell JS so the
    // in-app player and the verse loop don't hang in a phantom "playing" state.
    if (!self.interruptionRegistered) {
        self.interruptionRegistered = YES;
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(sessionInterrupted:)
                                                     name:AVAudioSessionInterruptionNotification
                                                   object:nil];
    }
    AVAudioSession *s = [AVAudioSession sharedInstance];
    NSError *catErr = nil;
    NSError *actErr = nil;
    // Force Playback + Default mode. The shared AVAudioSession may be left in
    // PlayAndRecord / VoiceChat / Measurement mode by the microphone (Rabbi AI voice chat),
    // the TTS plugin, or the WebView — which routes to the earpiece / narrowband voice
    // processing and makes verse audio sound bad. The full setCategory:mode:options: form
    // resets the mode to high-quality media playback (the 2-arg form does NOT reset mode).
    [s setCategory:AVAudioSessionCategoryPlayback
              mode:AVAudioSessionModeDefault
           options:0
             error:&catErr];
    [s setActive:YES error:&actErr];
    NSLog(@"[NativeAudioPlayer] session category=%@ mode=%@ catErr=%@ actErr=%@", s.category, s.mode, catErr, actErr);
}

- (void)setupTimeObserver {
    __weak NativeAudioPlayer *weakSelf = self;
    self.timeObserver = [self.player addPeriodicTimeObserverForInterval:CMTimeMakeWithSeconds(0.1, NSEC_PER_SEC)
                                                                  queue:dispatch_get_main_queue()
                                                             usingBlock:^(CMTime time) {
        NativeAudioPlayer *s = weakSelf;
        if (s == nil || s.player.rate == 0) { return; }
        NSMutableDictionary *p = [NSMutableDictionary dictionaryWithDictionary:
            @{ @"positionMs": @([s positionMs]), @"durationMs": @([s durationMs]) }];
        if (s.queueActive && s.queueIndex < (NSInteger)s.queueAbsIndex.count) {
            p[@"index"] = s.queueAbsIndex[s.queueIndex];
            p[@"id"] = [s currentQueueMeta][@"id"] ?: @"";
        }
        [s emit:@"position" payload:p];
        [s updateNowPlayingElapsed];
    }];
}

- (void)setupRemoteCommands {
    // Register handlers ONCE for the app lifetime. They reference self.player (updated on
    // each load), so they always control the current verse. Re-adding them per load would
    // accumulate duplicate handlers, so a single PLAY press would fire replay() N times.
    if (self.remoteCommandsRegistered) { return; }
    self.remoteCommandsRegistered = YES;
    MPRemoteCommandCenter *c = [MPRemoteCommandCenter sharedCommandCenter];
    __weak NativeAudioPlayer *weakSelf = self;
    [c.playCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *e) {
        [weakSelf.player play]; [weakSelf emitControl:@"play"]; return MPRemoteCommandHandlerStatusSuccess; }];
    [c.pauseCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *e) {
        [weakSelf.player pause]; [weakSelf emitControl:@"pause"]; return MPRemoteCommandHandlerStatusSuccess; }];
    [c.nextTrackCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *e) {
        NativeAudioPlayer *s = weakSelf;
        if (s.queueActive && [s.player isKindOfClass:[AVQueuePlayer class]]) {
            // Navigate the native queue directly — JS may be frozen in the background.
            [(AVQueuePlayer *)s.player advanceToNextItem];
            [s.player play];
            [s queueMovedForward];
        } else {
            [s emitControl:@"next"];
        }
        return MPRemoteCommandHandlerStatusSuccess; }];
    [c.previousTrackCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *e) {
        NativeAudioPlayer *s = weakSelf;
        if (s.queueActive) {
            // AVQueuePlayer can't go backwards; restart the current verse (standard behavior).
            [s.player seekToTime:kCMTimeZero];
            [s updateNowPlayingElapsed];
        } else {
            [s emitControl:@"previous"];
        }
        return MPRemoteCommandHandlerStatusSuccess; }];
    c.nextTrackCommand.enabled = YES;
    c.previousTrackCommand.enabled = YES;
    [c.changePlaybackPositionCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *e) {
        MPChangePlaybackPositionCommandEvent *pe = (MPChangePlaybackPositionCommandEvent *)e;
        [weakSelf.player seekToTime:CMTimeMakeWithSeconds(pe.positionTime, NSEC_PER_SEC)];
        [weakSelf emitControl:@"seek"]; return MPRemoteCommandHandlerStatusSuccess; }];
}

- (void)updateNowPlayingInfo:(NSDictionary*)opts {
    if (self.nowPlaying == nil) { self.nowPlaying = [NSMutableDictionary dictionary]; }
    if (opts[@"title"]) { self.nowPlaying[MPMediaItemPropertyTitle] = opts[@"title"]; }
    if (opts[@"artist"]) { self.nowPlaying[MPMediaItemPropertyArtist] = opts[@"artist"]; }
    if (opts[@"album"]) { self.nowPlaying[MPMediaItemPropertyAlbumTitle] = opts[@"album"]; }
    self.nowPlaying[MPNowPlayingInfoPropertyPlaybackRate] = @(self.player.rate);
    [[MPNowPlayingInfoCenter defaultCenter] setNowPlayingInfo:self.nowPlaying];

    NSString *artwork = opts[@"artwork"];
    if (artwork.length > 0) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSData *data = [NSData dataWithContentsOfURL:[NSURL URLWithString:artwork]];
            UIImage *img = data ? [UIImage imageWithData:data] : nil;
            if (img == nil) { return; }
            dispatch_async(dispatch_get_main_queue(), ^{
                MPMediaItemArtwork *art = [[MPMediaItemArtwork alloc] initWithBoundsSize:img.size
                                                                         requestHandler:^UIImage * _Nonnull(CGSize size) { return img; }];
                self.nowPlaying[MPMediaItemPropertyArtwork] = art;
                [[MPNowPlayingInfoCenter defaultCenter] setNowPlayingInfo:self.nowPlaying];
            });
        });
    }
}

- (void)updateNowPlayingElapsed {
    if (self.nowPlaying == nil) { return; }
    self.nowPlaying[MPNowPlayingInfoPropertyElapsedPlaybackTime] = @([self positionMs] / 1000.0);
    self.nowPlaying[MPMediaItemPropertyPlaybackDuration] = @([self durationMs] / 1000.0);
    self.nowPlaying[MPNowPlayingInfoPropertyPlaybackRate] = @(self.player.rate);
    [[MPNowPlayingInfoCenter defaultCenter] setNowPlayingInfo:self.nowPlaying];
}

- (void)itemDidEnd:(NSNotification*)n {
    if (self.looping) {
        // Silent keep-alive track: restart it seamlessly instead of ending.
        [self.player seekToTime:kCMTimeZero];
        [self.player play];
        return;
    }
    [self emit:@"ended" payload:@{}];
}

- (void)itemFailed:(NSNotification*)n {
    NSError *e = n.userInfo[AVPlayerItemFailedToPlayToEndTimeErrorKey];
    [self emit:@"error" payload:@{ @"code": @"player_error",
                                   @"message": e.localizedDescription ?: @"failed to play to end" }];
}

- (void)sessionInterrupted:(NSNotification*)n {
    NSUInteger type = [n.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];
    if (type == AVAudioSessionInterruptionTypeBegan) {
        [self.player pause];
        [self emitControl:@"pause"];
    }
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if ([keyPath isEqualToString:@"status"] && object == self.observedItem) {
        AVPlayerItem *item = (AVPlayerItem *)object;
        if (item.status == AVPlayerItemStatusFailed) {
            [self emit:@"error" payload:@{ @"code": @"player_error",
                                           @"message": item.error.localizedDescription ?: @"item failed" }];
        }
        return;
    }
    if ([keyPath isEqualToString:@"status"] && [self.queueItems containsObject:(AVPlayerItem *)object]) {
        AVPlayerItem *item = (AVPlayerItem *)object;
        if (item.status == AVPlayerItemStatusFailed && item == self.player.currentItem) {
            // A queued verse failed to LOAD (e.g. 404): report + skip so the queue moves on.
            [self emit:@"error" payload:@{ @"code": @"queue_item_failed",
                                           @"message": item.error.localizedDescription ?: @"queue item load failed" }];
            [self queueSkipFailedItem];
        }
        return;
    }
    [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
}

- (double)positionMs {
    if (self.player == nil) { return 0; }
    return CMTimeGetSeconds(self.player.currentTime) * 1000.0;
}

- (double)durationMs {
    // Prefer the clip length (real speech length); the item's own duration is unreliable.
    if (self.queueActive && self.player.currentItem != nil) {
        CMTime f = self.player.currentItem.forwardPlaybackEndTime;
        if (CMTIME_IS_VALID(f)) {
            double fs = CMTimeGetSeconds(f);
            if (fs > 0) { return fs * 1000.0; }
        }
    }
    if (self.clipDurationMs > 0) { return self.clipDurationMs; }
    if (self.displayDurationMs > 0) { return self.displayDurationMs; }
    if (self.player.currentItem == nil) { return 0; }
    double d = CMTimeGetSeconds(self.player.currentItem.duration);
    return isnan(d) ? 0 : d * 1000.0;
}

- (void)teardownPlayer {
    self.queueActive = NO;
    self.queueMeta = nil;
    self.queueAbsIndex = nil;
    self.queueIndex = 0;
    self.displayDurationMs = 0;
    for (AVPlayerItem *qi in self.queueItems) {
        @try { [qi removeObserver:self forKeyPath:@"status"]; } @catch (NSException *ex) { /* not registered */ }
    }
    self.queueItems = nil;
    if (self.timeObserver && self.player) { [self.player removeTimeObserver:self.timeObserver]; self.timeObserver = nil; }
    [[NSNotificationCenter defaultCenter] removeObserver:self name:AVPlayerItemDidPlayToEndTimeNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:AVPlayerItemFailedToPlayToEndTimeNotification object:nil];
    if (self.observedItem) {
        @try { [self.observedItem removeObserver:self forKeyPath:@"status"]; } @catch (NSException *ex) { /* not registered */ }
        self.observedItem = nil;
    }
    if (self.player) { [self.player pause]; self.player = nil; }
}

- (void)emitState {
    NSString *state = (self.player && self.player.rate != 0) ? @"playing" : @"paused";
    [self emit:@"state" payload:@{ @"state": state }];
}

- (void)emitControl:(NSString*)action { [self emit:@"control" payload:@{ @"action": action }]; }

- (void)emit:(NSString*)type payload:(NSDictionary*)payload {
    if (self.eventsCallbackId == nil) { return; }
    NSMutableDictionary *o = [payload mutableCopy] ?: [NSMutableDictionary dictionary];
    o[@"type"] = type;
    CDVPluginResult *r = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:o];
    [r setKeepCallbackAsBool:YES];
    [self.commandDelegate sendPluginResult:r callbackId:self.eventsCallbackId];
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
