# cordova-plugin-native-audio-player

Native background audio for Cordova/Ionic apps with the OS-native media player UI
(lock screen + notification + Control Center), the same components Spotify, YouTube
Music and Apple Podcasts use.

- **Android**: androidx Media3 (ExoPlayer + MediaSessionService + the default Media3
  notification). Foreground service with `mediaPlayback` type, so playback survives
  aggressive OEM battery managers.
- **iOS**: AVPlayer / AVQueuePlayer + MPNowPlayingInfoCenter + MPRemoteCommandCenter,
  with the `audio` background mode.
- **Native playlist** (`setQueue`): the OS advances tracks with zero JavaScript, so
  playback continues even when the WebView is frozen in the background.
- Position events (~10 Hz) for driving UI sync (e.g. word/line highlighting),
  transport-control events (play/pause/next/previous/seek), error events, per-track
  clipping to a given duration, playback-rate control, and a silent keep-alive loop
  for showing the OS player during non-file audio (e.g. device TTS).

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
// Play a single track (streams URLs, plays local file:// paths)
NativeAudioPlayer.load({
  url: 'https://example.com/track.mp3',
  title: 'Genesis 1:1',
  artist: 'My App',
  album: '',
  artwork: 'https://example.com/art-512.png',
  durationMs: 0,          // >0 clips the track natively to this length
  displayDurationMs: 0,   // >0 shows this length on the seekbar WITHOUT clipping
  autoplay: true
});

// Native playlist: the OS advances tracks with no JS involved (background-safe)
NativeAudioPlayer.setQueue([
  { url: '...', id: 'track-1', title: '...', durationMs: 12000 },
  { url: '...', id: 'track-2', title: '...', durationMs: 9000 }
], 0 /* startIndex */, 0 /* startPositionMs */);

NativeAudioPlayer.play();
NativeAudioPlayer.pause();
NativeAudioPlayer.stop();
NativeAudioPlayer.seekTo(5000);
NativeAudioPlayer.setRate(1.5);
NativeAudioPlayer.updateMetadata({ title: 'New title' });
NativeAudioPlayer.getPosition(function (p) { /* p.positionMs, p.durationMs */ });

// Show the OS media player while playing non-file audio (e.g. device TTS):
// loops a bundled silent track carrying your metadata + transport controls.
NativeAudioPlayer.playSilentLoop({ title: 'Genesis 1:1' });

// Events
NativeAudioPlayer.on('position',   function (e) { /* e.positionMs, e.durationMs, e.index?, e.id? */ });
NativeAudioPlayer.on('state',      function (e) { /* playing|paused|buffering|ended|stopped */ });
NativeAudioPlayer.on('control',    function (e) { /* e.action: play|pause|next|previous|seek */ });
NativeAudioPlayer.on('transition', function (e) { /* queue advanced: e.index, e.id */ });
NativeAudioPlayer.on('ended',      function (e) { /* track (or whole queue) finished */ });
NativeAudioPlayer.on('error',      function (e) { /* e.code, e.message */ });
```

## Behavior notes

- With a single loaded track, the notification's next/previous buttons are forced
  visible and forwarded to JS as `control` events (`next`/`previous`) so your app can
  decide what they do. With a queue (`setQueue`), the OS navigates the playlist
  natively and emits `transition` events.
- Audio-focus loss (phone call, another app) pauses playback and emits a `pause`
  control event so your UI can stay in sync.
- `durationMs` clipping exists because some generated/VBR MP3s report wrong durations
  or carry silent tails; clipping ends the track exactly where you say.

## Disclaimer

This software is provided **"as is"**, without warranty of any kind, express or
implied. The authors and copyright holders accept **no responsibility or liability**
for any claim, damages, data loss, store-review rejection, battery drain, or any
other consequence arising from installing or using this plugin, in any app or
environment. Use at your own risk and test thoroughly on your own devices. See the
[MIT License](LICENSE) for the full terms.

## License

[MIT](LICENSE)
