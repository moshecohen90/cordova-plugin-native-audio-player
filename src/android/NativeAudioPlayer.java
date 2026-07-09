package com.moshecohen.nativeaudio;

import android.content.ComponentName;
import android.net.Uri;
import android.os.Handler;
import android.os.Looper;
import android.text.TextUtils;

import androidx.annotation.OptIn;
import androidx.media3.common.MediaItem;
import androidx.media3.common.MediaMetadata;
import androidx.media3.common.PlaybackException;
import androidx.media3.common.Player;
import androidx.media3.common.util.UnstableApi;
import androidx.media3.datasource.RawResourceDataSource;
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

import java.util.ArrayList;
import java.util.List;

/**
 * Cordova bridge to the Media3 {@link PlaybackService}. Runs a {@link MediaController}
 * on the main thread; JS commands are marshalled onto it, and player events (state,
 * position, track transitions) are pushed back to JS through a kept-alive callback.
 */
@OptIn(markerClass = UnstableApi.class)
public class NativeAudioPlayer extends CordovaPlugin {
  private MediaController controller;
  private ListenableFuture<MediaController> controllerFuture;
  private final Handler main = new Handler(Looper.getMainLooper());

  private CallbackContext eventsCallback;
  private Runnable positionPoller;
  private static final long POSITION_INTERVAL_MS = 100;

  @Override
  public boolean execute(String action, JSONArray args, CallbackContext cb) {
    switch (action) {
      case "startEvents":
        this.eventsCallback = cb;
        keepAlive(cb);
        registerNavListener();
        return true;
      case "load":
        runOnMain(() -> load(args.optJSONObject(0), cb));
        return true;
      case "setQueue":
        runOnMain(() -> setQueue(args.optJSONArray(0), args.optInt(1, 0), args.optLong(2, 0), cb));
        return true;
      case "playSilentLoop":
        runOnMain(() -> playSilentLoop(args.optJSONObject(0), cb));
        return true;
      case "play":
        runOnMain(() -> { if (controller != null) controller.play(); ok(cb); });
        return true;
      case "pause":
        runOnMain(() -> { if (controller != null) controller.pause(); ok(cb); });
        return true;
      case "stop":
        runOnMain(() -> { if (controller != null) { controller.setRepeatMode(Player.REPEAT_MODE_OFF); controller.stop(); controller.clearMediaItems(); } ok(cb); });
        return true;
      case "seekTo":
        runOnMain(() -> { if (controller != null) controller.seekTo(args.optLong(0, 0)); ok(cb); });
        return true;
      case "setRate":
        runOnMain(() -> { if (controller != null) controller.setPlaybackSpeed((float) args.optDouble(0, 1.0)); ok(cb); });
        return true;
      case "updateMetadata":
        runOnMain(() -> { updateMetadata(args.optJSONObject(0)); ok(cb); });
        return true;
      case "getPosition":
        runOnMain(() -> getPosition(cb));
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
    // double-firing every event — 'ended' twice per verse skips verses.)
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
        startPositionPolling();
      } catch (Exception e) {
        emitError("controller_connect_failed", e.getMessage());
        pendingCommands.clear();
        return;
      }
      List<Runnable> toRun = new ArrayList<>(pendingCommands);
      pendingCommands.clear();
      for (Runnable r : toRun) { r.run(); }
    }, MoreExecutors.directExecutor());
  }

  // ---- commands ----

  // Note: callers reach these via runOnMain(), which guarantees the controller is
  // connected and we are on the main thread before the body runs.
  private void load(JSONObject opts, CallbackContext cb) {
    if (opts == null) { cb.error("missing options"); return; }
    controller.setRepeatMode(Player.REPEAT_MODE_OFF); // clear any silent-loop repeat
    MediaItem item = buildItem(opts);
    controller.setMediaItem(item);
    controller.prepare();
    if (opts.optBoolean("autoplay", true)) {
      controller.play();
    }
    ok(cb);
  }

  // Play the bundled silent clip on loop so the OS media notification shows during TTS
  // (which produces no native track of its own). REPEAT_MODE_ONE keeps the session alive
  // without ever reaching STATE_ENDED, so no spurious "ended" event fires.
  private void playSilentLoop(JSONObject opts, CallbackContext cb) {
    if (opts == null) opts = new JSONObject();
    int resId = cordova.getContext().getResources()
        .getIdentifier("silence", "raw", cordova.getContext().getPackageName());
    if (resId == 0) { cb.error("silence asset missing"); return; }
    MediaMetadata.Builder md = new MediaMetadata.Builder()
        .setTitle(opts.optString("title", ""))
        .setArtist(opts.optString("artist", ""))
        .setAlbumTitle(opts.optString("album", ""));
    String artwork = opts.optString("artwork", "");
    if (!TextUtils.isEmpty(artwork)) { md.setArtworkUri(Uri.parse(artwork)); }
    MediaItem item = new MediaItem.Builder()
        .setUri(RawResourceDataSource.buildRawResourceUri(resId))
        .setMediaId("silence")
        .setMediaMetadata(md.build())
        .build();
    controller.setRepeatMode(Player.REPEAT_MODE_ONE);
    controller.setMediaItem(item);
    controller.prepare();
    controller.play();
    ok(cb);
  }

  // Native playlist: the OS advances verse-to-verse with ZERO JavaScript, so playback
  // continues in the background even when the WebView is frozen (the JS verse loop dies
  // after ~30-60s backgrounded on aggressive OEMs — the Paul Deller churn bug).
  private void setQueue(JSONArray items, int startIndex, long startPositionMs, CallbackContext cb) {
    if (items == null) { cb.error("missing items"); return; }
    controller.setRepeatMode(Player.REPEAT_MODE_OFF);
    List<MediaItem> list = new ArrayList<>();
    for (int i = 0; i < items.length(); i++) {
      JSONObject o = items.optJSONObject(i);
      if (o != null) list.add(buildItem(o));
    }
    if (list.isEmpty()) { cb.error("empty queue"); return; }
    controller.setMediaItems(list, Math.max(0, Math.min(startIndex, list.size() - 1)), Math.max(0, startPositionMs));
    controller.prepare();
    controller.play();
    ok(cb);
  }

  private void updateMetadata(JSONObject opts) {
    if (controller == null || opts == null || controller.getMediaItemCount() == 0) return;
    // Merge ONLY the metadata into the playing item. Rebuilding from opts alone would
    // produce an empty-URI item (JS metadata refreshes carry no url) and kill playback.
    int idx = controller.getCurrentMediaItemIndex();
    MediaItem current = controller.getMediaItemAt(idx);
    MediaMetadata.Builder md = current.mediaMetadata.buildUpon();
    if (opts.has("title")) md.setTitle(opts.optString("title", ""));
    if (opts.has("artist")) md.setArtist(opts.optString("artist", ""));
    if (opts.has("album")) md.setAlbumTitle(opts.optString("album", ""));
    String artwork = opts.optString("artwork", "");
    if (!TextUtils.isEmpty(artwork)) md.setArtworkUri(Uri.parse(artwork));
    controller.replaceMediaItem(idx, current.buildUpon().setMediaMetadata(md.build()).build());
  }

  private void getPosition(CallbackContext cb) {
    if (controller == null) { cb.error("not ready"); return; }
    try {
      JSONObject r = new JSONObject();
      r.put("positionMs", controller.getCurrentPosition());
      r.put("durationMs", controller.getDuration());
      cb.success(r);
    } catch (JSONException e) {
      cb.error(e.getMessage());
    }
  }

  private MediaItem buildItem(JSONObject o) {
    MediaMetadata.Builder md = new MediaMetadata.Builder()
        .setTitle(o.optString("title", ""))
        .setArtist(o.optString("artist", ""))
        .setAlbumTitle(o.optString("album", ""));
    String artwork = o.optString("artwork", "");
    if (!TextUtils.isEmpty(artwork)) {
      md.setArtworkUri(Uri.parse(artwork));
    }
    long durationMs = o.optLong("durationMs", 0);
    // displayDurationMs: show the REAL speech length on the seekbar without clipping.
    // (Single-verse mode must not clip — the clip freezes the position at the boundary —
    // but the MP3's own duration includes bogus trailing silence, so the seekbar lies.)
    long displayDurationMs = o.optLong("displayDurationMs", 0);
    if (displayDurationMs <= 0) displayDurationMs = durationMs;
    if (displayDurationMs > 0) {
      md.setDurationMs(displayDurationMs);
    }
    MediaItem.Builder builder = new MediaItem.Builder()
        .setUri(o.optString("url"))
        .setMediaId(o.optString("id", o.optString("url")))
        .setMediaMetadata(md.build());
    // Clip to the real speech length (queue items only): playback ends exactly at the
    // end of speech with no JS involved — required for background auto-advance.
    if (durationMs > 0) {
      builder.setClippingConfiguration(
          new MediaItem.ClippingConfiguration.Builder().setEndPositionMs(durationMs).build());
    }
    return builder.build();
  }

  // ---- events ----

  private class PlayerEvents implements Player.Listener {
    @Override
    public void onPlaybackStateChanged(int state) {
      emitState();
      if (state == Player.STATE_ENDED) {
        emit("ended", null);
      }
    }

    @Override
    public void onIsPlayingChanged(boolean isPlaying) {
      emitState();
    }

    @Override
    public void onPlayWhenReadyChanged(boolean playWhenReady, int reason) {
      // Audio-focus loss / becoming-noisy pause ExoPlayer INTERNALLY (bypassing the
      // ForwardingPlayer wrapper), so without this the app's verse loop hangs mid-verse
      // after a phone call. User-requested pauses already reach the app via the wrapper.
      if (!playWhenReady && reason != Player.PLAY_WHEN_READY_CHANGE_REASON_USER_REQUEST) {
        emit("control", controlPayload("pause"));
      }
      emitState();
    }

    @Override
    public void onMediaItemTransition(MediaItem item, int reason) {
      JSONObject o = new JSONObject();
      try {
        o.put("index", controller != null ? controller.getCurrentMediaItemIndex() : -1);
        o.put("id", item != null ? item.mediaId : null);
        o.put("reason", reason); // AUTO=1 (track ended), SEEK/next-prev=2
      } catch (JSONException ignored) {}
      emit("transition", o);
    }

    @Override
    public void onPlayerError(PlaybackException error) {
      emitError("player_error", error.getMessage());
    }
  }

  private void startPositionPolling() {
    if (positionPoller != null) return;
    positionPoller = new Runnable() {
      @Override
      public void run() {
        if (controller != null && controller.isPlaying()) {
          JSONObject o = new JSONObject();
          try {
            o.put("positionMs", controller.getCurrentPosition());
            o.put("durationMs", controller.getDuration());
            o.put("index", controller.getCurrentMediaItemIndex());
            MediaItem cur = controller.getCurrentMediaItem();
            o.put("id", cur != null ? cur.mediaId : null);
          } catch (JSONException ignored) {}
          emit("position", o);
        }
        main.postDelayed(this, POSITION_INTERVAL_MS);
      }
    };
    main.postDelayed(positionPoller, POSITION_INTERVAL_MS);
  }

  private void emitState() {
    if (controller == null) return;
    String state;
    switch (controller.getPlaybackState()) {
      case Player.STATE_BUFFERING: state = "buffering"; break;
      case Player.STATE_ENDED: state = "ended"; break;
      case Player.STATE_IDLE: state = "stopped"; break;
      default: state = controller.isPlaying() ? "playing" : "paused";
    }
    JSONObject o = new JSONObject();
    try { o.put("state", state); } catch (JSONException ignored) {}
    emit("state", o);
  }

  private void emitError(String code, String message) {
    JSONObject o = new JSONObject();
    try { o.put("code", code); o.put("message", message); } catch (JSONException ignored) {}
    emit("error", o);
  }

  /** Route the notification's prev/next buttons (from PlaybackService) to the JS control stream. */
  private void registerNavListener() {
    PlaybackService.setNavListener(new PlaybackService.NavListener() {
      @Override
      public void onNext() { emit("control", controlPayload("next")); }
      @Override
      public void onPrevious() { emit("control", controlPayload("previous")); }
      @Override
      public void onPause() { emit("control", controlPayload("pause")); }
    });
  }

  private JSONObject controlPayload(String action) {
    JSONObject o = new JSONObject();
    try { o.put("action", action); } catch (JSONException ignored) {}
    return o;
  }

  private void emit(String type, JSONObject payload) {
    if (eventsCallback == null) return;
    JSONObject o = payload != null ? payload : new JSONObject();
    try { o.put("type", type); } catch (JSONException ignored) {}
    PluginResult r = new PluginResult(PluginResult.Status.OK, o);
    r.setKeepCallback(true);
    eventsCallback.sendPluginResult(r);
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
    if (positionPoller != null) { main.removeCallbacks(positionPoller); positionPoller = null; }
    if (controller != null) { controller.release(); controller = null; }
    if (controllerFuture != null) { MediaController.releaseFuture(controllerFuture); controllerFuture = null; }
    super.onDestroy();
  }
}
