# cordova-plugin-native-audio-player

Native background audio for Cordova/Ionic apps with the OS-native media player UI
(lock screen + notification + Control Center), the same components Spotify, YouTube
Music and Apple Podcasts use.

- **Android**: androidx Media3 (ExoPlayer + MediaSessionService + the default Media3
  notification). Foreground service with `mediaPlayback` type, so playback survives
  aggressive OEM battery managers.
- **iOS**: AVQueuePlayer + MPNowPlayingInfoCenter + MPRemoteCommandCenter, with the
  `audio` background mode.
- **Native queue** (`setQueue`): the OS advances items with zero JavaScript, so
  playback continues even when the WebView is frozen in the background.
- **Event-driven protocol, no polling**: state changes are deduped natively; every
  event carries `generation` + `seq` so stale/duplicated deliveries are droppable.
  Position is available on demand via `getState()` — there are NO periodic position
  events by design.
- **Verse/segment boundaries**: items flagged `boundary: true` start a logical unit
  (e.g. a verse). Lock-screen next/previous seek by boundary natively, so a queue of
  he/en segment pairs navigates whole verses.
- **Native TTS to file** (`synthesizeToFile` + `getVoices`): pre-synthesize device
  TTS into cacheable audio files (with word timestamps where the engine supports
  them), so TTS content can live in the same native queue as regular audio files.

## Install

```bash
cordova plugin add https://github.com/moshecohen90/cordova-plugin-native-audio-player.git
```

Or in `package.json` (works from CI / GitHub Actions):

```json
"cordova-plugin-native-audio-player": "github:moshecohen90/cordova-plugin-native-audio-player"
```

Requirements: cordova-android >= 13 (compileSdk 34+), iOS 13+.

For Google Play you must declare the `mediaPlayback` foreground-service type in the
Play Console (App content > Foreground service permissions).

If your app's `config.xml` already contains an `edit-config` for `UIBackgroundModes`,
make sure it includes `<string>audio</string>` — an app-level `edit-config` overrides
the entry this plugin adds.

## Usage

```js
NativeAudioPlayer.setEvents(function (evt) {
  // evt.type: 'state' | 'transition' | 'ended' | 'error'
  // every payload: { type, generation, seq, ... }
  // state:      { state: 'playing'|'paused'|'buffering'|'idle', reason?: 'user'|'interruption'|'focus'|'noisy', index, positionMs, rate }
  // transition: { index, id, tag }
  // error:      { code, message, index? }
});

NativeAudioPlayer.setQueue({
  generation: 1,
  items: [
    { id: '1:0', url: 'https://example.com/gen-1-1-he.mp3', clipEndMs: 11800, boundary: true,
      metadata: { title: 'Genesis 1:1', artist: 'My App', artworkUrl: 'https://example.com/art-512.png' },
      tag: '{"verseIndex":"1.1.1","lang":"he"}' },
    { id: '1:1', url: 'file:///.../gen-1-1-en.caf', boundary: false,
      metadata: { title: 'Genesis 1:1', artist: 'My App' },
      tag: '{"verseIndex":"1.1.1","lang":"en"}' }
  ],
  startIndex: 0,
  startPositionMs: 0,
  rate: 1.0,
  autoplay: true
}).then(...);

NativeAudioPlayer.appendQueue({ generation: 1, items: [...] });   // rejects on stale generation
NativeAudioPlayer.play();
NativeAudioPlayer.pause();          // keeps the media card visible (paused)
NativeAudioPlayer.stop();           // clears the queue and dismisses the card
NativeAudioPlayer.seekToItem({ index: 4, positionMs: 0 });
NativeAudioPlayer.setRate(1.5);     // pitch-preserving, persists across item advances
NativeAudioPlayer.getState().then(function (s) {
  // { generation, state, reason?, index, id, positionMs, durationMs, rate }
});

NativeAudioPlayer.getVoices().then(function (voices) {
  // [{ id, name, locale, quality, requiresNetwork }]
});
NativeAudioPlayer.synthesizeToFile({
  text: 'In the beginning...',
  voiceId: 'com.apple.voice.compact.en-US.Samantha',
  utteranceId: 'sha1-of-text-and-voice'
}).then(function (r) {
  // { fileUrl, durationMs, wordTimestamps: [{ charStart, charEnd, startMs }] }
  // cached natively by utteranceId; synthesis always runs at rate 1.0
});
```

## Behavior notes

- OS interruptions (phone call, Siri, focus loss, headphones unplugged) are absorbed
  natively and surface only as deduped `state` events with a `reason`; interruption
  end auto-resumes when the system allows it. JS needs zero recovery logic.
- `clipEndMs` clipping exists because some generated/VBR MP3s report wrong durations
  or carry silent tails; clipping ends the item exactly where you say, natively.
- Debug builds log structured `[AUD]`/`AUD` markers (events, transitions, a 15s
  heartbeat) to the native log for automated device testing. Release builds do not.

## Disclaimer

This software is provided **"as is"**, without warranty of any kind, express or
implied. The authors and copyright holders accept **no responsibility or liability**
for any claim, damages, data loss, store-review rejection, battery drain, or any
other consequence arising from installing or using this plugin, in any app or
environment. Use at your own risk and test thoroughly on your own devices. See the
[MIT License](LICENSE) for the full terms.

## License

[MIT](LICENSE)
