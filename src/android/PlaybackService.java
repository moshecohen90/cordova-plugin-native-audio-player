package com.moshecohen.nativeaudio;

import android.content.Intent;

import androidx.annotation.Nullable;
import androidx.annotation.OptIn;
import androidx.media3.common.AudioAttributes;
import androidx.media3.common.C;
import androidx.media3.common.ForwardingPlayer;
import androidx.media3.common.Player;
import androidx.media3.common.util.UnstableApi;
import androidx.media3.exoplayer.ExoPlayer;
import androidx.media3.session.MediaSession;
import androidx.media3.session.MediaSessionService;

/**
 * Media3 MediaSessionService. Owning the ExoPlayer here (not in the WebView) is what
 * gives us the OS-native media notification / lock-screen player — the same component
 * YouTube Music and Spotify use — plus reliable background playback and audio focus.
 * Media3 posts and tears down the foreground notification automatically.
 */
@OptIn(markerClass = UnstableApi.class)
public class PlaybackService extends MediaSessionService {
  private MediaSession mediaSession = null;

  /** Lets the plugin route the notification's transport buttons to the app. */
  public interface NavListener {
    void onNext();
    void onPrevious();
    void onPause();
  }
  private static NavListener navListener = null;
  public static void setNavListener(NavListener l) { navListener = l; }

  @Override
  public void onCreate() {
    super.onCreate();
    ExoPlayer player = new ExoPlayer.Builder(this)
        .setAudioAttributes(
            new AudioAttributes.Builder()
                .setUsage(C.USAGE_MEDIA)
                .setContentType(C.AUDIO_CONTENT_TYPE_SPEECH)
                .build(),
            /* handleAudioFocus= */ true)
        .setHandleAudioBecomingNoisy(true)
        .build();

    // Single-verse mode (no playlist): Media3 would hide "next" and make "prev" only restart
    // the verse, so force both buttons and forward them to the app. Queue mode (background
    // playlist): let Media3 navigate the playlist NATIVELY — the app's JS may be frozen.
    Player navPlayer = new ForwardingPlayer(player) {
      private boolean hasQueue() { return getMediaItemCount() > 1; }

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
      public boolean hasNextMediaItem() { return hasQueue() ? super.hasNextMediaItem() : true; }

      @Override
      public boolean hasPreviousMediaItem() { return hasQueue() ? super.hasPreviousMediaItem() : true; }

      @Override
      public void seekToNext() {
        if (hasQueue()) { super.seekToNext(); return; }
        if (navListener != null) navListener.onNext();
      }

      @Override
      public void seekToPrevious() {
        if (hasQueue()) { super.seekToPrevious(); return; }
        if (navListener != null) navListener.onPrevious();
      }

      @Override
      public void seekToNextMediaItem() {
        if (hasQueue()) { super.seekToNextMediaItem(); return; }
        if (navListener != null) navListener.onNext();
      }

      @Override
      public void seekToPreviousMediaItem() {
        if (hasQueue()) { super.seekToPreviousMediaItem(); return; }
        if (navListener != null) navListener.onPrevious();
      }

      // Route pause to the app so its in-app toolbar stays in sync (the app has no
      // mid-verse resume, so a user pause == stop). Media3 delivers the notification's
      // pause via pause() — which does NOT pass through setPlayWhenReady on a
      // ForwardingPlayer — so both entry points are overridden. The app's own
      // programmatic pause is suppressed on the JS side (it knows it asked).
      @Override
      public void pause() {
        if (getPlayWhenReady() && navListener != null) {
          navListener.onPause();
        }
        super.pause();
      }

      @Override
      public void setPlayWhenReady(boolean playWhenReady) {
        if (!playWhenReady && getPlayWhenReady() && navListener != null) {
          navListener.onPause();
        }
        super.setPlayWhenReady(playWhenReady);
      }
    };

    mediaSession = new MediaSession.Builder(this, navPlayer).build();
  }

  @Override
  @Nullable
  public MediaSession onGetSession(MediaSession.ControllerInfo controllerInfo) {
    return mediaSession;
  }

  @Override
  public void onTaskRemoved(@Nullable Intent rootIntent) {
    Player player = mediaSession != null ? mediaSession.getPlayer() : null;
    // The silent TTS keep-alive loop has no JS driver once the task is swiped away —
    // without this check it would loop a "playing" notification forever.
    boolean silentKeepAlive = player != null && player.getMediaItemCount() > 0
        && player.getCurrentMediaItem() != null
        && "silence".equals(player.getCurrentMediaItem().mediaId);
    if (player == null || !player.getPlayWhenReady() || player.getMediaItemCount() == 0 || silentKeepAlive) {
      if (player != null) {
        player.stop();
        player.clearMediaItems();
      }
      stopSelf();
    }
  }

  @Override
  public void onDestroy() {
    if (mediaSession != null) {
      mediaSession.getPlayer().release();
      mediaSession.release();
      mediaSession = null;
    }
    super.onDestroy();
  }
}
