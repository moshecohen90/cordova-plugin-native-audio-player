var exec = require('cordova/exec');

var SERVICE = 'NativeAudioPlayer';
var listeners = { position: [], state: [], control: [], ended: [], error: [], transition: [] };
var eventsStarted = false;

function emit(evt) {
  var type = evt && evt.type;
  var cbs = listeners[type] || [];
  for (var i = 0; i < cbs.length; i++) {
    try { cbs[i](evt); } catch (e) { /* ignore listener error */ }
  }
}

function startEvents() {
  if (eventsStarted) { return; }
  eventsStarted = true;
  exec(emit, function () {}, SERVICE, 'startEvents', []);
}

// The kept-alive events callback can DIE when Android recreates the Cordova bridge after
// the app was backgrounded (request/response calls still work, but position/state/ended
// events silently stop — killing UI sync). Re-register on every resume; the native side
// simply replaces its callback, so this is idempotent.
document.addEventListener('resume', function () {
  if (eventsStarted) {
    exec(emit, function () {}, SERVICE, 'startEvents', []);
  }
}, false);

var NativeAudioPlayer = {
  /**
   * Load a track and start (or prepare) playback.
   * @param {{url:string,title?:string,artist?:string,album?:string,artwork?:string,durationMs?:number,autoplay?:boolean}} options
   */
  load: function (options, success, error) {
    startEvents();
    exec(success, error, SERVICE, 'load', [options || {}]);
  },

  /**
   * Replace the play queue with a native playlist. The OS advances between tracks with
   * zero JavaScript, so playback survives a frozen/backgrounded WebView. Emits a
   * 'transition' event ({index, id}) on every track change and 'ended' when exhausted.
   */
  setQueue: function (items, startIndex, startPositionMs, success, error) {
    startEvents();
    exec(success, error, SERVICE, 'setQueue', [items || [], startIndex || 0, startPositionMs || 0]);
  },

  /**
   * Append upcoming tracks AFTER the currently playing one (iOS): the current track keeps
   * playing untouched (optionally clipped to currentEndMs) and the OS advances into the
   * appended list natively — safe to call mid-track on backgrounding.
   */
  appendQueue: function (items, currentEndMs, success, error) {
    startEvents();
    exec(success, error, SERVICE, 'appendQueue', [items || [], currentEndMs || 0]);
  },

  /**
   * Play a bundled silent track on loop, showing the OS media player (Now Playing /
   * notification) with the given metadata + transport controls. Used during TTS, which
   * produces no native track of its own, so the lock-screen player still appears.
   * @param {{title?:string,artist?:string,album?:string,artwork?:string}} options
   */
  playSilentLoop: function (options, success, error) {
    startEvents();
    exec(success, error, SERVICE, 'playSilentLoop', [options || {}]);
  },

  play: function (success, error) { exec(success, error, SERVICE, 'play', []); },
  pause: function (success, error) { exec(success, error, SERVICE, 'pause', []); },
  stop: function (success, error) { exec(success, error, SERVICE, 'stop', []); },
  seekTo: function (ms, success, error) { exec(success, error, SERVICE, 'seekTo', [ms]); },
  setRate: function (rate, success, error) { exec(success, error, SERVICE, 'setRate', [rate]); },

  /** Update the now-playing metadata without changing the track. */
  updateMetadata: function (options, success, error) {
    exec(success, error, SERVICE, 'updateMetadata', [options || {}]);
  },

  /** Async: current position in milliseconds. */
  getPosition: function (success, error) { exec(success, error, SERVICE, 'getPosition', []); },

  /**
   * Subscribe to native events.
   * @param {'position'|'state'|'control'|'ended'|'error'|'transition'} type
   * @param {(evt:object)=>void} cb
   */
  on: function (type, cb) {
    if (listeners[type] && typeof cb === 'function') {
      listeners[type].push(cb);
      startEvents();
    }
  },

  off: function (type, cb) {
    if (!listeners[type]) { return; }
    listeners[type] = listeners[type].filter(function (f) { return f !== cb; });
  }
};

module.exports = NativeAudioPlayer;
