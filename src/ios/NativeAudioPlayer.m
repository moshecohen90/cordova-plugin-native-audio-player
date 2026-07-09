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
// The app-level intent: should audio be playing right now? Drives background recovery.
@property (nonatomic) BOOL shouldBePlaying;
// Requested playback rate (setRate) — must be re-applied after every queue advance:
// AVPlayer's play resets the rate, which would silently drop x2 back to x1 mid-queue.
@property (nonatomic) float requestedRate;
// Keeps the process alive while AVPlayer buffers in the background: a buffering gap plays
// no audio, and with a silent audio session iOS suspends the app within seconds — freezing
// the download forever. A background task buys ~30s per gap, plenty for a verse MP3.
@property (nonatomic) UIBackgroundTaskIdentifier bufferKeepAlive;
// Native queue (background verse-to-verse continuity with zero JS).
@property (nonatomic, strong) NSMutableArray<NSDictionary*> *queueMeta;   // FULL caller array
@property (nonatomic, strong) NSMutableArray<NSNumber*> *queueAbsIndex;   // player order -> abs index
@property (nonatomic, strong) NSMutableArray<AVPlayerItem*> *queueItems;  // observed player items
@property (nonatomic) NSInteger queueIndex;                               // position in player order
@property (nonatomic) BOOL queueActive;
@end

@implementation NativeAudioPlayer

- (void)pluginInitialize {
    self.bufferKeepAlive = UIBackgroundTaskInvalid;
}

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
    // AVQueuePlayer from the start: a background handoff can then APPEND upcoming verses
    // after this one with zero interruption (an AVPlayer can't be upgraded in place).
    self.player = [AVQueuePlayer queuePlayerWithItems:@[item]];
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
    self.shouldBePlaying = autoplay;
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
        AVPlayerItem *item = [self buildQueueItemFrom:items[i] absIndex:i];
        if (item == nil) { continue; }
        [playerItems addObject:item];
    }
    if (playerItems.count == 0) { [self fail:command msg:@"no valid items"]; return; }

    self.queueIndex = 0;
    self.queueActive = YES;
    // Keep automaticallyWaitsToMinimizeStalling at its default (YES): per Apple, with NO an
    // empty buffer resets the rate to 0 and playback NEVER self-recovers — exactly the
    // "background playback wedges when the next verse needs the network" bug. With YES the
    // player parks on WaitingToPlayAtSpecifiedRate and resumes by itself; we just keep the
    // process alive through the silent gap (see beginBufferKeepAlive).
    self.player = [AVQueuePlayer queuePlayerWithItems:playerItems];
    [self setupTimeObserver];
    [self setupRemoteCommands];
    if (startPosMs > 0) {
        [self.player seekToTime:CMTimeMakeWithSeconds(startPosMs / 1000.0, NSEC_PER_SEC)];
    }
    self.shouldBePlaying = YES;
    [self.player play];
    [self updateNowPlayingInfo:[self currentQueueMeta]];
    [self updateNowPlayingElapsed];
    [self emitState];
    [self ok:command];
}

/** Meta of the currently playing queue item (player order -> absolute index). */
- (NSDictionary *)currentQueueMeta {
    if (!self.queueActive || self.queueIndex < 0 || self.queueIndex >= (NSInteger)self.queueAbsIndex.count) { return @{}; }
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
    [self queueAdvanceAfter:(AVPlayerItem *)n.object];
}

// A CLIPPED item (forwardPlaybackEndTime) fires DidPlayToEnd but does NOT auto-advance
// an AVQueuePlayer — the queue just stops there. Advance manually, restore the playback
// rate (play resets it to 1), and keep the session alive.
- (void)queueAdvanceAfter:(AVPlayerItem *)ended {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.queueActive) { return; }
        if ([self.player isKindOfClass:[AVQueuePlayer class]] && self.player.currentItem == ended) {
            [(AVQueuePlayer *)self.player advanceToNextItem];
        }
        [self.player play];
        if (self.requestedRate > 0 && self.requestedRate != 1) {
            self.player.rate = self.requestedRate;
        }
        [self queueMovedForward];
        NSLog(@"[NativeAudioPlayer] queue advanced -> index %ld (rate=%f)", (long)self.queueIndex, self.player.rate);
    });
}

- (void)queueMovedForward {
    self.queueIndex++;
    if (self.queueIndex >= (NSInteger)self.queueAbsIndex.count) {
        self.queueActive = NO;
        self.shouldBePlaying = NO;
        [self endBufferKeepAlive];
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

    self.shouldBePlaying = YES;
    [self.player play];
    [self updateNowPlayingInfo:opts];
    [self updateNowPlayingElapsed];
    [self emitState];
    [self ok:command];
}

// Build one queue AVPlayerItem (clip + pitch + observers) and register bookkeeping.
- (AVPlayerItem *)buildQueueItemFrom:(NSDictionary *)o absIndex:(NSInteger)i {
    NSURL *u = [self urlFromString:o[@"url"]];
    if (u == nil) { return nil; }
    AVPlayerItem *item = [AVPlayerItem playerItemWithURL:u];
    item.audioTimePitchAlgorithm = AVAudioTimePitchAlgorithmSpectral;
    double dur = [[o objectForKey:@"durationMs"] doubleValue];
    if (dur > 0) {
        item.forwardPlaybackEndTime = CMTimeMakeWithSeconds(dur / 1000.0, NSEC_PER_SEC);
    }
    [self.queueAbsIndex addObject:@(i)];
    [self.queueItems addObject:item];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(queueItemDidEnd:)
        name:AVPlayerItemDidPlayToEndTimeNotification object:item];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(queueItemFailed:)
        name:AVPlayerItemFailedToPlayToEndTimeNotification object:item];
    [item addObserver:self forKeyPath:@"status" options:NSKeyValueObservingOptionNew context:nil];
    return item;
}

// Background handoff WITHOUT touching the playing verse: append the upcoming verses after
// the current item and give the current item a real end point (JS is about to be frozen,
// so it can no longer cut the trailing silence or advance verses itself).
- (void)appendQueue:(CDVInvokedUrlCommand*)command {
    NSArray *items = [command argumentAtIndex:0 withDefault:@[]];
    double currentEndMs = [[command argumentAtIndex:1 withDefault:@0] doubleValue];
    if (![self.player isKindOfClass:[AVQueuePlayer class]] || self.player.currentItem == nil) {
        [self fail:command msg:@"no active player"]; return;
    }
    if (items.count == 0) { [self fail:command msg:@"empty items"]; return; }
    AVQueuePlayer *qp = (AVQueuePlayer *)self.player;

    if (currentEndMs > 0 && currentEndMs > [self positionMs] + 300) {
        self.player.currentItem.forwardPlaybackEndTime = CMTimeMakeWithSeconds(currentEndMs / 1000.0, NSEC_PER_SEC);
    }

    self.queueMeta = [items mutableCopy];
    self.queueAbsIndex = [NSMutableArray array];
    self.queueItems = [NSMutableArray array];
    self.queueIndex = -1; // the pre-queue item is still playing

    AVPlayerItem *after = qp.items.lastObject;
    NSInteger appended = 0;
    for (NSInteger i = 0; i < (NSInteger)items.count; i++) {
        AVPlayerItem *item = [self buildQueueItemFrom:items[i] absIndex:i];
        if (item == nil) { continue; }
        if ([qp canInsertItem:item afterItem:after]) {
            [qp insertItem:item afterItem:after];
            after = item;
            appended++;
        }
    }
    if (appended == 0) { [self fail:command msg:@"nothing appended"]; return; }
    self.queueActive = YES;
    self.shouldBePlaying = YES;
    NSLog(@"[NativeAudioPlayer] appendQueue: %ld items after current (currentEndMs=%.0f)", (long)appended, currentEndMs);
    [self ok:command];
}

- (void)play:(CDVInvokedUrlCommand*)command {
    self.shouldBePlaying = YES;
    if (self.player) { [self.player play]; [self emitState]; }
    [self ok:command];
}

- (void)pause:(CDVInvokedUrlCommand*)command {
    self.shouldBePlaying = NO;
    [self endBufferKeepAlive];
    if (self.player) { [self.player pause]; [self emitState]; }
    [self ok:command];
}

- (void)stop:(CDVInvokedUrlCommand*)command {
    self.shouldBePlaying = NO;
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
    self.requestedRate = rate;
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
        // WKWebView silently re-flips the SHARED AVAudioSession category under us, so at
        // background-entry the media system can consider the app non-entitled and post a
        // Pause. Re-assert the session on every background entry (we still have runtime).
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(appEnteredBackground:)
                                                     name:UIApplicationDidEnterBackgroundNotification
                                                   object:nil];
        // The current item ran out of buffered data (streaming verse in the background).
        // With waits=YES the player recovers on its own; we just have to survive the gap.
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(playbackStalled:)
                                                     name:AVPlayerItemPlaybackStalledNotification
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
    // Track buffering: WaitingToPlayAtSpecifiedRate means the player is silent while it
    // loads — hold a background task so iOS doesn't suspend us mid-download.
    [self.player addObserver:self forKeyPath:@"timeControlStatus"
                     options:NSKeyValueObservingOptionNew context:nil];
    __weak NativeAudioPlayer *weakSelf = self;
    self.timeObserver = [self.player addPeriodicTimeObserverForInterval:CMTimeMakeWithSeconds(0.1, NSEC_PER_SEC)
                                                                  queue:dispatch_get_main_queue()
                                                             usingBlock:^(CMTime time) {
        NativeAudioPlayer *s = weakSelf;
        if (s == nil || s.player.rate == 0) { return; }
        NSMutableDictionary *p = [NSMutableDictionary dictionaryWithDictionary:
            @{ @"positionMs": @([s positionMs]), @"durationMs": @([s durationMs]) }];
        if (s.queueActive && s.queueIndex >= 0 && s.queueIndex < (NSInteger)s.queueAbsIndex.count) {
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
        weakSelf.shouldBePlaying = YES;
        [weakSelf.player play]; [weakSelf emitControl:@"play"]; return MPRemoteCommandHandlerStatusSuccess; }];
    [c.pauseCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *e) {
        weakSelf.shouldBePlaying = NO;
        [weakSelf.player pause]; [weakSelf updateNowPlayingElapsed];
        [weakSelf emitControl:@"pause"]; return MPRemoteCommandHandlerStatusSuccess; }];
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
    if (self.queueActive && self.queueIndex < 0) {
        // The pre-queue item finished; advance into the appended queue (a clipped item
        // does not auto-advance the AVQueuePlayer).
        [self queueAdvanceAfter:(AVPlayerItem *)n.object];
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
    if (type != AVAudioSessionInterruptionTypeBegan) { return; }
    // Backgrounding "interruption": iOS pauses us because WKWebView flipped the shared
    // session's category out from under our Playback config. If we SHOULD be playing,
    // re-assert the session and resume on the spot — a real interruption (phone call)
    // fails session activation here and falls through to the pause path.
    if (self.shouldBePlaying && self.player != nil &&
        [UIApplication sharedApplication].applicationState != UIApplicationStateActive) {
        AVAudioSession *s = [AVAudioSession sharedInstance];
        NSError *catErr = nil; NSError *actErr = nil;
        [s setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeDefault options:0 error:&catErr];
        [s setActive:YES error:&actErr];
        if (actErr == nil) {
            [self.player play];
            NSLog(@"[NativeAudioPlayer] background interruption -> session re-asserted, playback resumed");
            return;
        }
        NSLog(@"[NativeAudioPlayer] background interruption -> session reactivation FAILED: %@", actErr);
    }
    [self.player pause];
    [self emitControl:@"pause"];
}

- (void)appEnteredBackground:(NSNotification*)n {
    if (!self.shouldBePlaying || self.player == nil) { return; }
    AVAudioSession *s = [AVAudioSession sharedInstance];
    NSError *actErr = nil;
    [s setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeDefault options:0 error:nil];
    [s setActive:YES error:&actErr];
    if (self.player.rate == 0) { [self.player play]; }
    // Already buffering at background-entry: no timeControl change will fire, so make sure
    // the keep-alive is held right now.
    if (self.player.timeControlStatus != AVPlayerTimeControlStatusPlaying) { [self beginBufferKeepAlive]; }
    NSLog(@"[NativeAudioPlayer] entered background: session re-asserted (actErr=%@) rate=%f timeControl=%ld",
          actErr, self.player.rate, (long)self.player.timeControlStatus);
}

// Buffering keep-alive: while the player is loading (silent), iOS sees no audio and can
// suspend the app; a named background task keeps the process (and the download) running.
- (void)beginBufferKeepAlive {
    if (self.bufferKeepAlive != UIBackgroundTaskInvalid) { return; }
    __weak NativeAudioPlayer *weakSelf = self;
    self.bufferKeepAlive = [[UIApplication sharedApplication]
        beginBackgroundTaskWithName:@"audio-buffering"
                  expirationHandler:^{ [weakSelf endBufferKeepAlive]; }];
    NSLog(@"[NativeAudioPlayer] buffering keep-alive begun");
}

- (void)endBufferKeepAlive {
    if (self.bufferKeepAlive == UIBackgroundTaskInvalid) { return; }
    [[UIApplication sharedApplication] endBackgroundTask:self.bufferKeepAlive];
    self.bufferKeepAlive = UIBackgroundTaskInvalid;
}

- (void)timeControlChanged {
    if (self.player == nil) { return; }
    AVPlayerTimeControlStatus st = self.player.timeControlStatus;
    if (st == AVPlayerTimeControlStatusPlaying) {
        [self endBufferKeepAlive];
        return;
    }
    if (!self.shouldBePlaying) { return; }
    [self beginBufferKeepAlive];
    if (st == AVPlayerTimeControlStatusPaused && self.player.currentItem != nil) {
        // An intentionally playing player should never park on Paused (waits=YES buffers on
        // Waiting instead) — this is the stall-reset path, kick playback back on.
        NSLog(@"[NativeAudioPlayer] timeControl Paused while shouldBePlaying -> re-play");
        [self.player play];
    }
}

- (void)playbackStalled:(NSNotification*)n {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.shouldBePlaying || self.player == nil) { return; }
        NSLog(@"[NativeAudioPlayer] playback stalled (timeControl=%ld) -> keep-alive", (long)self.player.timeControlStatus);
        [self beginBufferKeepAlive];
        if (self.player.timeControlStatus == AVPlayerTimeControlStatusPaused) { [self.player play]; }
    });
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if ([keyPath isEqualToString:@"timeControlStatus"] && object == self.player) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self timeControlChanged]; });
        return;
    }
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
    if (self.player) {
        @try { [self.player removeObserver:self forKeyPath:@"timeControlStatus"]; } @catch (NSException *ex) { /* not registered */ }
        [self.player pause];
        self.player = nil;
    }
    [self endBufferKeepAlive];
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
