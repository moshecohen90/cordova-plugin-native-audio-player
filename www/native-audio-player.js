var exec = require('cordova/exec');

var SERVICE = 'NativeAudioPlayer';
var eventsHandler = null;
var eventsBound = false;

function dispatch(evt) {
  if (eventsHandler) { eventsHandler(evt); }
}

function bindEvents() {
  eventsBound = true;
  exec(dispatch, function () {}, SERVICE, 'setEvents', []);
}

/**
 * The kept-alive events callback can die when the platform recreates the Cordova bridge
 * after backgrounding (request/response calls keep working while events silently stop).
 * Re-binding on resume is idempotent: the native side replaces its stored callback.
 */
document.addEventListener('resume', function () {
  if (eventsBound) { bindEvents(); }
}, false);

function call(action, args) {
  return new Promise(function (resolve, reject) {
    exec(resolve, reject, SERVICE, action, args || []);
  });
}

var NativeAudioPlayer = {
  /**
   * Registers THE single events handler (replaces any previous one).
   * Every event payload carries {type, generation, seq}; types:
   * state {state, reason?, index, positionMs, rate} | transition {index, id, tag} |
   * ended {} | error {code, message, index?}.
   */
  setEvents: function (handler) {
    eventsHandler = handler;
    bindEvents();
  },

  /**
   * Replaces the native queue. Items: {id, url, clipEndMs?, boundary, metadata:{title,
   * artist, album?, artworkUrl?}, tag}. The OS advances items natively (zero JS), so
   * playback survives a frozen background WebView. tag is opaque JSON echoed in
   * transition events.
   */
  setQueue: function (opts) { return call('setQueue', [opts || {}]); },

  /** Appends items after the queue tail. Rejected when opts.generation is stale. */
  appendQueue: function (opts) { return call('appendQueue', [opts || {}]); },

  play: function () { return call('play'); },
  pause: function () { return call('pause'); },
  stop: function () { return call('stop'); },

  /** Jumps to an absolute queue index (optionally to a position within it). */
  seekToItem: function (opts) { return call('seekToItem', [opts || {}]); },

  /** Pitch-preserving playback speed, persisted natively across item advances. */
  setRate: function (rate) { return call('setRate', [rate]); },

  /** Snapshot {generation, state, reason?, index, id, positionMs, durationMs, rate}. */
  getState: function () { return call('getState'); },

  /** Native TTS voices: [{id, name, locale, quality, requiresNetwork}]. */
  getVoices: function () { return call('getVoices'); },

  /**
   * Synthesizes text to an audio file at rate 1.0 (playback speed is applied by the
   * player), cached natively by utteranceId. Resolves
   * {fileUrl, durationMs, wordTimestamps:[{charStart, charEnd, startMs}]}.
   */
  synthesizeToFile: function (opts) { return call('synthesizeToFile', [opts || {}]); },

  /** Writes a line to the native audit log (debug builds only; used by test harnesses). */
  audit: function (line) { exec(function () {}, function () {}, SERVICE, 'audit', [String(line || '')]); }
};

module.exports = NativeAudioPlayer;
