package com.moshecohen.nativeaudio;

import android.content.ComponentName;
import android.content.pm.ApplicationInfo;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.speech.tts.TextToSpeech;
import android.speech.tts.UtteranceProgressListener;
import android.speech.tts.Voice;
import android.text.TextUtils;
import android.util.Log;

import androidx.annotation.OptIn;
import androidx.media3.common.MediaItem;
import androidx.media3.common.MediaMetadata;
import androidx.media3.common.PlaybackException;
import androidx.media3.common.Player;
import androidx.media3.common.util.UnstableApi;
import androidx.media3.session.MediaController;
import androidx.media3.session.SessionToken;

import com.google.common.util.concurrent.ListenableFuture;
import com.google.common.util.concurrent.MoreExecutors;

import org.apache.cordova.CallbackContext;
import org.apache.cordova.CordovaPlugin;
import org.apache.cordova.PluginResult;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileWriter;
import java.io.IOException;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * Cordova bridge to the Media3 {@link PlaybackService}. Commands are marshalled onto the
 * main thread through a MediaController; player events flow back to JS through a single
 * kept-alive callback. Every event carries the queue generation plus a monotonic seq so
 * JS can drop stale or duplicated deliveries. No periodic position events are emitted.
 */
@OptIn(markerClass = UnstableApi.class)
public class NativeAudioPlayer extends CordovaPlugin {
  private static final String AUDIT_TAG = "AUD";
  private static final String POST_NOTIFICATIONS = "android.permission.POST_NOTIFICATIONS";

  private MediaController controller;
  private ListenableFuture<MediaController> controllerFuture;
  private final Handler main = new Handler(Looper.getMainLooper());

  private CallbackContext eventsCallback;
  private long generation = 0;
  private long seq = 0;
  private String lastEmittedState;
  private String lastEmittedReason;
  private int lastPlayWhenReadyReason = Player.PLAY_WHEN_READY_CHANGE_REASON_USER_REQUEST;
  private boolean notificationPermissionRequested;
  private boolean audit;

  private TextToSpeech tts;
  private boolean ttsReady;
  private boolean ttsFailed;
  private final List<Runnable> ttsPending = new ArrayList<>();
  private final Map<String, SynthJob> synthJobs = new HashMap<>();

  @Override
  protected void pluginInitialize() {
    audit = (cordova.getContext().getApplicationInfo().flags & ApplicationInfo.FLAG_DEBUGGABLE) != 0;
  }

  @Override
  public boolean execute(String action, JSONArray args, CallbackContext cb) {
    switch (action) {
      case "setEvents":
        this.eventsCallback = cb;
        keepAlive(cb);
        return true;
      case "setQueue":
        runOnMain(() -> setQueue(args.optJSONObject(0), cb));
        return true;
      case "appendQueue":
        runOnMain(() -> appendQueue(args.optJSONObject(0), cb));
        return true;
      case "play":
        runOnMain(() -> { if (controller != null) controller.play(); ok(cb); });
        return true;
      case "pause":
        runOnMain(() -> { if (controller != null) controller.pause(); ok(cb); });
        return true;
      case "stop":
        runOnMain(() -> { if (controller != null) { controller.stop(); controller.clearMediaItems(); } ok(cb); });
        return true;
      case "seekToItem":
        runOnMain(() -> seekToItem(args.optJSONObject(0), cb));
        return true;
      case "setRate":
        runOnMain(() -> { if (controller != null) controller.setPlaybackSpeed((float) args.optDouble(0, 1.0)); ok(cb); });
        return true;
      case "getState":
        runOnMain(() -> getState(cb));
        return true;
      case "getVoices":
        main.post(() -> ensureTts(() -> getVoices(cb)));
        return true;
      case "synthesizeToFile":
        main.post(() -> synthesizeToFile(args.optJSONObject(0), cb));
        return true;
      case "audit":
        if (audit) Log.i(AUDIT_TAG, args.optString(0));
        ok(cb);
        return true;
      default:
        return false;
    }
  }

  // ---- controller lifecycle ----

  private final List<Runnable> pendingCommands = new ArrayList<>();

  private void ensureController(Runnable whenReady) {
    if (controller != null) { whenReady.run(); return; }
    // Queue the command; the ONE future-listener below runs them all after connecting.
    // (One completion listener per queued command would register duplicate PlayerEvents,
    // double-firing every event.)
    pendingCommands.add(whenReady);
    if (controllerFuture != null) { return; }
    SessionToken token = new SessionToken(
        cordova.getContext(),
        new ComponentName(cordova.getContext(), PlaybackService.class));
    controllerFuture = new MediaController.Builder(cordova.getContext(), token).buildAsync();
    controllerFuture.addListener(() -> {
      try {
        controller = controllerFuture.get();
        controller.addListener(new PlayerEvents());
      } catch (Exception e) {
        emitError("controller_connect_failed", e.getMessage(), -1);
        pendingCommands.clear();
        return;
      }
      List<Runnable> toRun = new ArrayList<>(pendingCommands);
      pendingCommands.clear();
      for (Runnable r : toRun) { r.run(); }
    }, MoreExecutors.directExecutor());
  }

  // ---- commands ----

  private void setQueue(JSONObject opts, CallbackContext cb) {
    JSONArray items = opts != null ? opts.optJSONArray("items") : null;
    if (items == null || items.length() == 0) { cb.error("empty queue"); return; }
    requestNotificationPermission();
    generation = opts.optLong("generation", 0);
    lastEmittedState = null;
    lastEmittedReason = null;
    List<MediaItem> list = buildItems(items);
    if (list.isEmpty()) { cb.error("no valid items"); return; }
    int startIndex = Math.max(0, Math.min(opts.optInt("startIndex", 0), list.size() - 1));
    controller.setMediaItems(list, startIndex, Math.max(0, opts.optLong("startPositionMs", 0)));
    controller.setPlaybackSpeed((float) opts.optDouble("rate", 1.0));
    controller.prepare();
    if (opts.optBoolean("autoplay", true)) {
      controller.play();
    }
    ok(cb);
  }

  private void appendQueue(JSONObject opts, CallbackContext cb) {
    JSONArray items = opts != null ? opts.optJSONArray("items") : null;
    if (items == null || items.length() == 0) { cb.error("empty items"); return; }
    if (opts.optLong("generation", -1) != generation) { cb.error("stale generation"); return; }
    List<MediaItem> list = buildItems(items);
    if (list.isEmpty()) { cb.error("no valid items"); return; }
    controller.addMediaItems(list);
    ok(cb);
  }

  private void seekToItem(JSONObject opts, CallbackContext cb) {
    if (controller == null || opts == null) { cb.error("not ready"); return; }
    int index = opts.optInt("index", -1);
    if (index < 0 || index >= controller.getMediaItemCount()) { cb.error("index out of range"); return; }
    controller.seekTo(index, Math.max(0, opts.optLong("positionMs", 0)));
    ok(cb);
  }

  private void getState(CallbackContext cb) {
    try {
      JSONObject r = new JSONObject();
      r.put("generation", generation);
      if (controller == null || controller.getMediaItemCount() == 0) {
        r.put("state", "idle");
      } else {
        r.put("state", computeState());
        String reason = computeReason();
        if (reason != null) r.put("reason", reason);
        r.put("index", controller.getCurrentMediaItemIndex());
        MediaItem cur = controller.getCurrentMediaItem();
        r.put("id", cur != null ? cur.mediaId : null);
        r.put("positionMs", realPositionMs());
        r.put("durationMs", controller.getDuration());
        r.put("rate", controller.getPlaybackParameters().speed);
      }
      cb.success(r);
    } catch (JSONException e) {
      cb.error(e.getMessage());
    }
  }

  private List<MediaItem> buildItems(JSONArray items) {
    List<MediaItem> list = new ArrayList<>();
    for (int i = 0; i < items.length(); i++) {
      JSONObject o = items.optJSONObject(i);
      if (o != null && !TextUtils.isEmpty(o.optString("url"))) list.add(buildItem(o));
    }
    return list;
  }

  private MediaItem buildItem(JSONObject o) {
    JSONObject meta = o.optJSONObject("metadata");
    if (meta == null) meta = new JSONObject();
    Bundle extras = new Bundle();
    extras.putBoolean("boundary", o.optBoolean("boundary", true));
    extras.putString("tag", o.optString("tag", ""));
    MediaMetadata.Builder md = new MediaMetadata.Builder()
        .setTitle(meta.optString("title", ""))
        .setArtist(meta.optString("artist", ""))
        .setAlbumTitle(meta.optString("album", ""))
        .setExtras(extras);
    String artwork = meta.optString("artworkUrl", "");
    if (!TextUtils.isEmpty(artwork)) {
      md.setArtworkUri(Uri.parse(artwork));
    }
    long clipEndMs = o.optLong("clipEndMs", 0);
    if (clipEndMs > 0) {
      md.setDurationMs(clipEndMs);
    }
    MediaItem.Builder builder = new MediaItem.Builder()
        .setUri(resolveUrl(o.optString("url")))
        .setMediaId(o.optString("id", o.optString("url")))
        .setMediaMetadata(md.build());
    // Clip to the real speech length: playback ends exactly at the end of speech with no
    // JS involved, which is what makes background auto-advance reliable.
    if (clipEndMs > 0) {
      builder.setClippingConfiguration(
          new MediaItem.ClippingConfiguration.Builder().setEndPositionMs(clipEndMs).build());
    }
    return builder.build();
  }

  /**
   * WebView-relative urls (bundled app assets like "assets/data/mp3/...") point inside
   * the packaged www folder, which ExoPlayer reads through the asset scheme.
   */
  private String resolveUrl(String url) {
    if (url.contains("://")) return url;
    return "asset:///www/" + url;
  }

  /**
   * Position from the REAL player (same process) when available: the MediaController's
   * extrapolated position can freeze mid-item (observed on Android 16).
   */
  private long realPositionMs() {
    long fromService = PlaybackService.currentPositionMs();
    return fromService >= 0 ? fromService : controller.getCurrentPosition();
  }

  private void requestNotificationPermission() {
    if (notificationPermissionRequested || Build.VERSION.SDK_INT < 33) return;
    notificationPermissionRequested = true;
    if (!cordova.hasPermission(POST_NOTIFICATIONS)) {
      cordova.requestPermission(this, 0, POST_NOTIFICATIONS);
    }
  }

  // ---- events ----

  private class PlayerEvents implements Player.Listener {
    @Override
    public void onPlaybackStateChanged(int state) {
      if (state == Player.STATE_ENDED) {
        emit("ended", new JSONObject());
      }
      maybeEmitState();
    }

    @Override
    public void onIsPlayingChanged(boolean isPlaying) {
      maybeEmitState();
    }

    @Override
    public void onPlayWhenReadyChanged(boolean playWhenReady, int reason) {
      lastPlayWhenReadyReason = reason;
      maybeEmitState();
    }

    @Override
    public void onMediaItemTransition(MediaItem item, int reason) {
      if (controller == null || item == null) return;
      JSONObject o = new JSONObject();
      try {
        o.put("index", controller.getCurrentMediaItemIndex());
        o.put("id", item.mediaId);
        Bundle extras = item.mediaMetadata.extras;
        o.put("tag", extras != null ? extras.getString("tag", "") : "");
      } catch (JSONException ignored) {}
      emit("transition", o);
    }

    @Override
    public void onPlayerError(PlaybackException error) {
      emitError("player_error", error.getMessage(),
          controller != null ? controller.getCurrentMediaItemIndex() : -1);
    }
  }

  private String computeState() {
    switch (controller.getPlaybackState()) {
      case Player.STATE_BUFFERING: return "buffering";
      case Player.STATE_IDLE:
      case Player.STATE_ENDED: return "idle";
      default: return controller.isPlaying() ? "playing" : "paused";
    }
  }

  private String computeReason() {
    if (!"paused".equals(computeState())) return null;
    switch (lastPlayWhenReadyReason) {
      case Player.PLAY_WHEN_READY_CHANGE_REASON_AUDIO_FOCUS_LOSS: return "focus";
      case Player.PLAY_WHEN_READY_CHANGE_REASON_AUDIO_BECOMING_NOISY: return "noisy";
      default: return "user";
    }
  }

  /** Emits a state event only when the normalized (state, reason) tuple changed. */
  private void maybeEmitState() {
    if (controller == null) return;
    String state = computeState();
    String reason = computeReason();
    if (state.equals(lastEmittedState) && TextUtils.equals(reason, lastEmittedReason)) return;
    lastEmittedState = state;
    lastEmittedReason = reason;
    JSONObject o = new JSONObject();
    try {
      o.put("state", state);
      if (reason != null) o.put("reason", reason);
      o.put("index", controller.getCurrentMediaItemIndex());
      o.put("positionMs", realPositionMs());
      o.put("rate", controller.getPlaybackParameters().speed);
    } catch (JSONException ignored) {}
    emit("state", o);
  }

  private void emitError(String code, String message, int index) {
    JSONObject o = new JSONObject();
    try {
      o.put("code", code);
      o.put("message", message);
      if (index >= 0) o.put("index", index);
    } catch (JSONException ignored) {}
    emit("error", o);
  }

  private void emit(String type, JSONObject payload) {
    JSONObject o = payload != null ? payload : new JSONObject();
    try {
      o.put("type", type);
      o.put("generation", generation);
      o.put("seq", ++seq);
    } catch (JSONException ignored) {}
    if (audit) Log.i(AUDIT_TAG, type + " " + o);
    if (eventsCallback == null) return;
    PluginResult r = new PluginResult(PluginResult.Status.OK, o);
    r.setKeepCallback(true);
    eventsCallback.sendPluginResult(r);
  }

  // ---- TTS synthesis ----

  private static class SynthJob {
    CallbackContext cb;
    File wav;
    File sidecar;
    int sampleRate;
    JSONArray timestamps = new JSONArray();
  }

  private void ensureTts(Runnable whenReady) {
    if (ttsReady) { whenReady.run(); return; }
    if (ttsFailed) { whenReady.run(); return; }
    ttsPending.add(whenReady);
    if (tts != null) return;
    tts = new TextToSpeech(cordova.getContext(), status -> main.post(() -> {
      if (status == TextToSpeech.SUCCESS) {
        ttsReady = true;
        tts.setOnUtteranceProgressListener(new SynthListener());
      } else {
        ttsFailed = true;
      }
      List<Runnable> toRun = new ArrayList<>(ttsPending);
      ttsPending.clear();
      for (Runnable r : toRun) { r.run(); }
    }));
  }

  private void getVoices(CallbackContext cb) {
    if (!ttsReady) { cb.error("tts unavailable"); return; }
    try {
      JSONArray arr = new JSONArray();
      for (Voice v : tts.getVoices()) {
        JSONObject o = new JSONObject();
        o.put("id", v.getName());
        o.put("name", v.getName());
        o.put("locale", v.getLocale().toLanguageTag());
        o.put("quality", v.getQuality());
        o.put("requiresNetwork", v.isNetworkConnectionRequired());
        arr.put(o);
      }
      cb.success(arr);
    } catch (Exception e) {
      cb.error("voices unavailable: " + e.getMessage());
    }
  }

  private void synthesizeToFile(JSONObject opts, CallbackContext cb) {
    if (opts == null) { cb.error("missing options"); return; }
    String text = opts.optString("text");
    String voiceId = opts.optString("voiceId");
    String utteranceId = opts.optString("utteranceId");
    if (TextUtils.isEmpty(text) || TextUtils.isEmpty(utteranceId)) { cb.error("missing text or utteranceId"); return; }

    File dir = new File(cordova.getContext().getCacheDir(), "tts-cache");
    if (!dir.exists() && !dir.mkdirs()) { cb.error("cache dir unavailable"); return; }
    File wav = new File(dir, utteranceId + ".wav");
    File sidecar = new File(dir, utteranceId + ".json");
    if (wav.exists() && sidecar.exists()) {
      JSONObject cached = readSidecar(sidecar, wav);
      if (cached != null) { cb.success(cached); return; }
    }

    ensureTts(() -> {
      if (!ttsReady) { cb.error("tts unavailable"); return; }
      Voice voice = findVoice(voiceId);
      if (voice == null) { cb.error("voice not found: " + voiceId); return; }
      tts.setVoice(voice);
      tts.setSpeechRate(1.0f);
      SynthJob job = new SynthJob();
      job.cb = cb;
      job.wav = wav;
      job.sidecar = sidecar;
      synthJobs.put(utteranceId, job);
      int r = tts.synthesizeToFile(text, new Bundle(), wav, utteranceId);
      if (r != TextToSpeech.SUCCESS) {
        synthJobs.remove(utteranceId);
        cb.error("synthesis start failed");
      }
    });
  }

  private Voice findVoice(String voiceId) {
    if (TextUtils.isEmpty(voiceId)) return tts.getVoice() != null ? tts.getVoice() : tts.getDefaultVoice();
    for (Voice v : tts.getVoices()) {
      if (v.getName().equals(voiceId)) return v;
    }
    return null;
  }

  private class SynthListener extends UtteranceProgressListener {
    @Override
    public void onStart(String utteranceId) {}

    @Override
    public void onBeginSynthesis(String utteranceId, int sampleRateInHz, int audioFormat, int channelCount) {
      main.post(() -> {
        SynthJob job = synthJobs.get(utteranceId);
        if (job != null) job.sampleRate = sampleRateInHz;
      });
    }

    @Override
    public void onRangeStart(String utteranceId, int start, int end, int frame) {
      main.post(() -> {
        SynthJob job = synthJobs.get(utteranceId);
        if (job == null || job.sampleRate <= 0) return;
        try {
          JSONObject t = new JSONObject();
          t.put("charStart", start);
          t.put("charEnd", end);
          t.put("startMs", frame * 1000L / job.sampleRate);
          job.timestamps.put(t);
        } catch (JSONException ignored) {}
      });
    }

    @Override
    public void onDone(String utteranceId) {
      main.post(() -> finishSynthJob(utteranceId));
    }

    @Override
    public void onError(String utteranceId) {
      main.post(() -> failSynthJob(utteranceId, "synthesis failed"));
    }

    @Override
    public void onError(String utteranceId, int errorCode) {
      main.post(() -> failSynthJob(utteranceId, "synthesis failed: " + errorCode));
    }
  }

  private void finishSynthJob(String utteranceId) {
    SynthJob job = synthJobs.remove(utteranceId);
    if (job == null) return;
    long durationMs = wavDurationMs(job.wav);
    if (durationMs <= 0) {
      job.wav.delete();
      job.cb.error("synthesized file invalid");
      return;
    }
    try {
      JSONObject result = new JSONObject();
      result.put("fileUrl", "file://" + job.wav.getAbsolutePath());
      result.put("durationMs", durationMs);
      result.put("wordTimestamps", job.timestamps);
      writeSidecar(job.sidecar, durationMs, job.timestamps);
      job.cb.success(result);
    } catch (JSONException e) {
      job.cb.error(e.getMessage());
    }
  }

  private void failSynthJob(String utteranceId, String message) {
    SynthJob job = synthJobs.remove(utteranceId);
    if (job == null) return;
    job.wav.delete();
    job.cb.error(message);
  }

  /** Duration from the WAV header (byteRate at offset 28, data size before the samples). */
  private long wavDurationMs(File wav) {
    try (FileInputStream in = new FileInputStream(wav)) {
      byte[] header = new byte[44];
      if (in.read(header) < 44) return 0;
      long byteRate = readLeInt(header, 28);
      long dataSize = wav.length() - 44;
      if (byteRate <= 0 || dataSize <= 0) return 0;
      return dataSize * 1000L / byteRate;
    } catch (IOException e) {
      return 0;
    }
  }

  private long readLeInt(byte[] b, int off) {
    return (b[off] & 0xFFL) | ((b[off + 1] & 0xFFL) << 8) | ((b[off + 2] & 0xFFL) << 16) | ((b[off + 3] & 0xFFL) << 24);
  }

  private void writeSidecar(File sidecar, long durationMs, JSONArray timestamps) {
    try (FileWriter w = new FileWriter(sidecar)) {
      JSONObject o = new JSONObject();
      o.put("durationMs", durationMs);
      o.put("wordTimestamps", timestamps);
      w.write(o.toString());
    } catch (IOException | JSONException ignored) {}
  }

  private JSONObject readSidecar(File sidecar, File wav) {
    try (InputStreamReader r = new InputStreamReader(new FileInputStream(sidecar), StandardCharsets.UTF_8)) {
      char[] buf = new char[(int) sidecar.length()];
      int n = r.read(buf);
      JSONObject o = new JSONObject(new String(buf, 0, Math.max(0, n)));
      o.put("fileUrl", "file://" + wav.getAbsolutePath());
      return o;
    } catch (IOException | JSONException e) {
      return null;
    }
  }

  // ---- helpers ----

  private void runOnMain(Runnable r) {
    main.post(() -> ensureController(r));
  }

  private void keepAlive(CallbackContext cb) {
    PluginResult r = new PluginResult(PluginResult.Status.NO_RESULT);
    r.setKeepCallback(true);
    cb.sendPluginResult(r);
  }

  private void ok(CallbackContext cb) {
    if (cb != null) cb.success();
  }

  @Override
  public void onDestroy() {
    if (controller != null) { controller.release(); controller = null; }
    if (controllerFuture != null) { MediaController.releaseFuture(controllerFuture); controllerFuture = null; }
    if (tts != null) { tts.shutdown(); tts = null; }
    super.onDestroy();
  }
}
