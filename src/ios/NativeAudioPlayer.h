#import <Cordova/CDVPlugin.h>
#import <AVFoundation/AVFoundation.h>

@interface NativeAudioPlayer : CDVPlugin <AVSpeechSynthesizerDelegate>

- (void)setEvents:(CDVInvokedUrlCommand*)command;
- (void)setQueue:(CDVInvokedUrlCommand*)command;
- (void)appendQueue:(CDVInvokedUrlCommand*)command;
- (void)play:(CDVInvokedUrlCommand*)command;
- (void)pause:(CDVInvokedUrlCommand*)command;
- (void)stop:(CDVInvokedUrlCommand*)command;
- (void)seekToItem:(CDVInvokedUrlCommand*)command;
- (void)setRate:(CDVInvokedUrlCommand*)command;
- (void)getState:(CDVInvokedUrlCommand*)command;
- (void)getVoices:(CDVInvokedUrlCommand*)command;
- (void)synthesizeToFile:(CDVInvokedUrlCommand*)command;
- (void)audit:(CDVInvokedUrlCommand*)command;

@end
