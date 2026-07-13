package com.moshecohen.nativeaudio;

import android.content.Intent;
import android.content.pm.ApplicationInfo;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;

import androidx.annotation.Nullable;
import androidx.annotation.OptIn;
import androidx.media3.common.AudioAttributes;
import androidx.media3.common.C;
import androidx.media3.common.ForwardingPlayer;
import androidx.media3.common.MediaItem;
import androidx.media3.common.Player;
import androidx.media3.common.util.UnstableApi;
import androidx.media3.exoplayer.ExoPlayer;
import androidx.media3.session.MediaSession;
import androidx.media3.session.MediaSessionService;

/**
 * Media3 MediaSessionService. Owning the ExoPlayer here (not in the WebView) is what gives
 * the OS-native media notification / lock-screen player, reliable background playback and
 * audio focus. Media3 posts and tears down the foreground notification automatically.
 *
 * Queue items are verse SEGMENTS; items flagged boundary=true (metadata extras) start a
 * verse. The notification's next/previous seek by verse boundary NATIVELY, so lock-screen
 * navigation works even when the WebView is frozen in the background.
 */
@OptIn(markerClass = UnstableApi.class)
public class PlaybackService extends MediaSessionService {
  private static final String AUDIT_TAG = "AUD";
  private static final long HEARTBEAT_MS = 15000;

  private MediaSession mediaSession = null;
  private final Handler main = new Handler(Looper.getMainLooper());
  private Runnable heartbeat;
  private boolean audit;

  // Same-process handle for reading the REAL player position. The plugin's
  // MediaController.getCurrentPosition() is an extrapolated estimate that can freeze
  // mid-item (seen on Android 16), which stalls word-highlighting while audio plays on.
  private static PlaybackService instance = null;

  /** Actual player position in ms, or -1 when the service/player is unavailable.
   *  Must be called on the main thread (the player's application thread). */
  public static long currentPositionMs() {
    PlaybackService s = instance;
    if (s == null || s.mediaSession == null) return -1;
    try {
      return s.mediaSession.getPlayer().getCurrentPosition();
    } catch (Exception e) {
      return -1;
    }
  }

  @Override
  public void onCreate() {
    super.onCreate();
    instance = this;
    audit = (getApplicationInfo().flags & ApplicationInfo.FLAG_DEBUGGABLE) != 0;
    ExoPlayer player = new ExoPlayer.Builder(this)
        .setAudioAttributes(
            new AudioAttributes.Builder()
                .setUsage(C.USAGE_MEDIA)
                .setContentType(C.AUDIO_CONTENT_TYPE_SPEECH)
                .build(),
            /* handleAudioFocus= */ true)
        .setHandleAudioBecomingNoisy(true)
        .build();

    Player versePlayer = new ForwardingPlayer(player) {
      private boolean isBoundary(int index) {
        MediaItem item = getMediaItemAt(index);
        Bundle extras = item.mediaMetadata.extras;
        return extras == null || extras.getBoolean("boundary", true);
      }

      private int currentVerseStart() {
        int i = getCurrentMediaItemIndex();
        while (i > 0 && !isBoundary(i)) { i--; }
        return i;
      }

      private void seekToNextVerse() {
        int count = getMediaItemCount();
        for (int i = getCurrentMediaItemIndex() + 1; i < count; i++) {
          if (isBoundary(i)) {
            auditControl("next", i);
            seekTo(i, 0);
            return;
          }
        }
      }

      private void seekToPreviousVerse() {
        int start = currentVerseStart();
        int target = start;
        for (int i = start - 1; i >= 0; i--) {
          if (isBoundary(i)) { target = i; break; }
        }
        auditControl("previous", target);
        seekTo(target, 0);
      }

      @Override
      public Commands getAvailableCommands() {
        return super.getAvailableCommands().buildUpon()
            .add(Player.COMMAND_SEEK_TO_NEXT)
            .add(Player.COMMAND_SEEK_TO_PREVIOUS)
            .build();
      }

      @Override
      public boolean isCommandAvailable(int command) {
        if (command == Player.COMMAND_SEEK_TO_NEXT || command == Player.COMMAND_SEEK_TO_PREVIOUS) {
          return true;
        }
        return super.isCommandAvailable(command);
      }

      @Override
      public boolean hasNextMediaItem() { return true; }

      @Override
      public boolean hasPreviousMediaItem() { return true; }

      @Override
      public void seekToNext() { seekToNextVerse(); }

      @Override
      public void seekToNextMediaItem() { seekToNextVerse(); }

      @Override
      public void seekToPrevious() { seekToPreviousVerse(); }

      @Override
      public void seekToPreviousMediaItem() { seekToPreviousVerse(); }
    };

    mediaSession = new MediaSession.Builder(this, versePlayer).build();
    if (audit) {
      player.addListener(new AuditEvents());
      startHeartbeat(player);
    }
  }

  @Override
  @Nullable
  public MediaSession onGetSession(MediaSession.ControllerInfo controllerInfo) {
    return mediaSession;
  }

  @Override
  public void onTaskRemoved(@Nullable Intent rootIntent) {
    Player player = mediaSession != null ? mediaSession.getPlayer() : null;
    if (player == null || !player.getPlayWhenReady() || player.getMediaItemCount() == 0) {
      if (player != null) {
        player.stop();
        player.clearMediaItems();
      }
      stopSelf();
    }
  }

  private void auditControl(String action, int targetIndex) {
    if (audit) Log.i(AUDIT_TAG, "control {\"action\":\"" + action + "\",\"origin\":\"notif\",\"target\":" + targetIndex + "}");
  }

  /** Service-side audit markers survive a frozen or dead WebView (same file: harness needs them). */
  private class AuditEvents implements Player.Listener {
    @Override
    public void onMediaItemTransition(MediaItem item, int reason) {
      Player p = mediaSession != null ? mediaSession.getPlayer() : null;
      Log.i(AUDIT_TAG, "svcTransition {\"index\":" + (p != null ? p.getCurrentMediaItemIndex() : -1)
          + ",\"id\":\"" + (item != null ? item.mediaId : "") + "\",\"reason\":" + reason + "}");
    }

    @Override
    public void onIsPlayingChanged(boolean isPlaying) {
      Log.i(AUDIT_TAG, "svcPlaying {\"playing\":" + isPlaying + "}");
    }

    @Override
    public void onPlaybackStateChanged(int state) {
      Log.i(AUDIT_TAG, "svcState {\"playbackState\":" + state + "}");
    }
  }

  private void startHeartbeat(ExoPlayer player) {
    heartbeat = () -> {
      if (player.getMediaItemCount() > 0) {
        MediaItem cur = player.getCurrentMediaItem();
        Log.i(AUDIT_TAG, "hb {\"pos\":" + player.getCurrentPosition()
            + ",\"qIdx\":" + player.getCurrentMediaItemIndex()
            + ",\"id\":\"" + (cur != null ? cur.mediaId : "") + "\""
            + ",\"playing\":" + player.isPlaying()
            + ",\"rate\":" + player.getPlaybackParameters().speed + "}");
      }
      main.postDelayed(heartbeat, HEARTBEAT_MS);
    };
    main.postDelayed(heartbeat, HEARTBEAT_MS);
  }

  @Override
  public void onDestroy() {
    instance = null;
    if (heartbeat != null) { main.removeCallbacks(heartbeat); heartbeat = null; }
    if (mediaSession != null) {
      mediaSession.getPlayer().release();
      mediaSession.release();
      mediaSession = null;
    }
    super.onDestroy();
  }
}
