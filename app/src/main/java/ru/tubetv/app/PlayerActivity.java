package ru.tubetv.app;

import android.Manifest;
import android.app.Activity;
import android.content.Intent;
import android.content.res.Configuration;
import android.graphics.Color;
import android.media.AudioManager;
import android.net.Uri;
import android.os.Bundle;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.MotionEvent;
import android.view.Surface;
import android.view.View;
import android.view.ViewConfiguration;
import android.view.WindowManager;
import android.view.animation.OvershootInterpolator;
import android.widget.FrameLayout;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.SeekBar;
import android.widget.TextView;

import androidx.annotation.OptIn;
import androidx.core.content.ContextCompat;
import androidx.core.graphics.Insets;
import androidx.core.view.ViewCompat;
import androidx.core.view.WindowCompat;
import androidx.core.view.WindowInsetsCompat;
import androidx.media3.common.AudioAttributes;
import androidx.media3.common.MediaItem;
import androidx.media3.common.C;
import androidx.media3.common.MimeTypes;
import androidx.media3.common.PlaybackException;
import androidx.media3.common.Player;
import androidx.media3.common.VideoSize;
import androidx.media3.common.util.UnstableApi;
import androidx.media3.datasource.DefaultHttpDataSource;
import androidx.media3.exoplayer.DefaultRenderersFactory;
import androidx.media3.exoplayer.ExoPlayer;
import androidx.media3.exoplayer.mediacodec.MediaCodecInfo;
import androidx.media3.exoplayer.mediacodec.MediaCodecSelector;
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory;

import java.util.ArrayList;
import java.net.CookieHandler;
import java.net.CookieManager;
import java.net.CookiePolicy;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public final class PlayerActivity extends Activity {
    private static final long PLAYING_CONTROLS_TIMEOUT_MS = 3500L;
    private static final long PAUSED_CONTROLS_TIMEOUT_MS = 1000L;
    private static final int CONTROLS_HEIGHT_DP = 122;
    private static final float[] PLAYBACK_SPEEDS = {0.75f, 1f, 1.25f, 1.5f, 2f};
    private final ExecutorService resolver = Executors.newSingleThreadExecutor();
    private final Handler ui = new Handler(Looper.getMainLooper());
    private final Runnable progressTicker = new Runnable() {
        @Override public void run() {
            updateControls();
            ui.postDelayed(this, 1000);
        }
    };
    private ExoPlayer player;
    private MirrorVideoView videoSurface;
    private ProgressBar loading;
    private SeekBar timeline;
    private TextView message;
    private TextView playState;
    private TextView settingsState;
    private TextView time;
    private LinearLayout controls;
    private LinearLayout playbackMenu;
    private LinearLayout mirrorOptions;
    private final List<TextView> speedOptions = new ArrayList<>();
    private TextView normalMirrorOption;
    private TextView mirroredOption;
    private FrameLayout.LayoutParams controlsLayoutParams;
    private final Runnable hideControls = () -> {
        controls.animate().cancel();
        controls.setTranslationY(0f);
        controls.clearFocus();
        controls.setVisibility(View.GONE);
    };
    private String streamUrl;
    private String streamMimeType;
    private String videoSource;
    private String videoIdentityUrl;
    private boolean autoPlay;
    private boolean trafficMode;
    private boolean audioOnly;
    private int targetHeight;
    private boolean scrubbing;
    private boolean controlsDragging;
    private boolean dpadScrubbing;
    private boolean heldSeekIsLong;
    private boolean mirrored;
    private boolean historyRecordedThisSession;
    private boolean playbackMenuVisible;
    private boolean centerLongPressTriggered;
    private boolean centerKeyHeld;
    private boolean audioMovedToBackground;
    private boolean leavingPlayer;
    private long resumePosition;
    private long knownDuration;
    private long lastSavedAt;
    private int videoWidth;
    private int videoHeight;
    private int safeLeft;
    private int safeRight;
    private int safeBottom;
    private int heldSeekKey = KeyEvent.KEYCODE_UNKNOWN;
    private long dpadSeekPosition;
    private float playbackSpeed;
    private VideoItem historyItem;
    private Thread.UncaughtExceptionHandler previousCrashHandler;
    private final Runnable openMenuFromLongCenter = () -> {
        if (centerKeyHeld && player != null) {
            centerLongPressTriggered = true;
            setPlaybackMenuVisible(true);
        }
    };
    private final Runnable beginHeldSeek = () -> {
        if (heldSeekKey == KeyEvent.KEYCODE_DPAD_LEFT
                || heldSeekKey == KeyEvent.KEYCODE_DPAD_RIGHT) {
            heldSeekIsLong = true;
            beginDpadScrub();
            moveDpadScrub(seekDelta(heldSeekKey));
        }
    };

    @Override protected void onCreate(Bundle state) {
        super.onCreate(state);
        WindowCompat.setDecorFitsSystemWindows(getWindow(), false);
        previousCrashHandler = Thread.getDefaultUncaughtExceptionHandler();
        Thread.setDefaultUncaughtExceptionHandler((thread, error) -> {
            CrashLog.save(getApplicationContext(), error);
            if (previousCrashHandler != null) previousCrashHandler.uncaughtException(thread, error);
        });
        autoPlay = getIntent().getBooleanExtra("auto_play", true);
        trafficMode = getIntent().getBooleanExtra("traffic_mode", false);
        audioOnly = getIntent().getBooleanExtra("audio_only", false);
        targetHeight = Math.max(0, getIntent().getIntExtra("target_height", 0));
        resumePosition = Math.max(0L, getIntent().getLongExtra("resume_position", 0L));
        videoSource = getIntent().getStringExtra("source");
        videoIdentityUrl = getIntent().getStringExtra("page_url");
        knownDuration = Math.max(0L, getIntent().getLongExtra("duration_ms", 0L));
        historyItem = new VideoItem(
                videoSource,
                getIntent().getStringExtra("title"),
                getIntent().getStringExtra("subtitle"),
                getIntent().getStringExtra("thumbnail"),
                getIntent().getStringExtra("resolver_url"),
                videoIdentityUrl,
                knownDuration)
                .withQuality(Math.max(0, getIntent().getIntExtra("max_width", 0)),
                        Math.max(0, getIntent().getIntExtra("max_height", 0)));
        historyRecordedThisSession = WatchHistoryStore.contains(this, historyItem);
        playbackSpeed = normalizedPlaybackSpeed(StateStore.playbackSpeed(this));
        if (videoIdentityUrl == null || videoIdentityUrl.isEmpty()) {
            videoIdentityUrl = getIntent().getStringExtra("resolver_url");
        }
        mirrored = WatchProgressStore.isMirrored(this, videoSource, videoIdentityUrl);
        if (getIntent().getBooleanExtra("resume_background_audio", false)) {
            stopService(new Intent(this, AudioPlaybackService.class));
            resumePosition = StateStore.position(this);
        }
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        getWindow().getDecorView().setSystemUiVisibility(View.SYSTEM_UI_FLAG_FULLSCREEN
                | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION | View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY);
        setVolumeControlStream(AudioManager.STREAM_MUSIC);
        setContentView(createContent());
        requestNotificationPermissionForAudio();
        resolveStream();
    }

    private View createContent() {
        FrameLayout root = new FrameLayout(this);
        root.setBackgroundColor(Color.BLACK);
        root.setOnTouchListener((view, event) -> {
            if (event.getActionMasked() == MotionEvent.ACTION_DOWN) {
                if (playbackMenuVisible) setPlaybackMenuVisible(false);
                else showControls();
            }
            return true;
        });
        videoSurface = new MirrorVideoView(this);
        videoSurface.setMirrored(mirrored);
        videoSurface.setSurfaceListener(new MirrorVideoView.SurfaceListener() {
            @Override public void onSurfaceAvailable(Surface surface) {
                if (player != null) player.setVideoSurface(surface);
            }

            @Override public void onSurfaceDestroyed(Surface surface) {
                if (player != null) player.clearVideoSurface(surface);
            }
        });
        root.addView(videoSurface, new FrameLayout.LayoutParams(-1, -1));
        ImageView speaker = new ImageView(this);
        speaker.setImageResource(R.drawable.ic_speaker);
        speaker.setScaleType(ImageView.ScaleType.CENTER_INSIDE);
        speaker.setVisibility(audioOnly ? View.VISIBLE : View.GONE);
        root.addView(speaker, new FrameLayout.LayoutParams(dp(112), dp(112), Gravity.CENTER));

        loading = new ProgressBar(this);
        root.addView(loading, new FrameLayout.LayoutParams(dp(64), dp(64), Gravity.CENTER));
        message = new TextView(this);
        message.setTextColor(Color.WHITE);
        message.setTextSize(18);
        message.setGravity(Gravity.CENTER);
        message.setPadding(dp(30), dp(20), dp(30), dp(20));
        root.addView(message, new FrameLayout.LayoutParams(-1, -2, Gravity.CENTER));
        message.setText("Получаю видеопоток…");

        controls = new DraggableControlsLayout();
        controls.setOrientation(LinearLayout.VERTICAL);
        controls.setBackgroundResource(R.drawable.player_controls_background);
        controls.setVisibility(audioOnly ? View.VISIBLE : View.GONE);

        playbackMenu = createPlaybackMenu();
        controls.addView(playbackMenu, new LinearLayout.LayoutParams(-1, dp(playbackMenuHeightDp())));

        LinearLayout titleRow = new LinearLayout(this);
        titleRow.setGravity(Gravity.CENTER_VERTICAL);
        TextView title = label(getIntent().getStringExtra("title"), isCompactPlayer() ? 14 : 17);
        title.setSingleLine(true);
        time = label("0:00 / 0:00", isCompactPlayer() ? 12 : 14);
        time.setGravity(Gravity.END | Gravity.CENTER_VERTICAL);
        titleRow.addView(title, new LinearLayout.LayoutParams(0, dp(28), 1f));
        titleRow.addView(time, new LinearLayout.LayoutParams(dp(isCompactPlayer() ? 112 : 150), dp(28)));
        controls.addView(titleRow, new LinearLayout.LayoutParams(-1, dp(28)));

        timeline = new SeekBar(this);
        timeline.setMax(1000);
        timeline.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener() {
            @Override public void onProgressChanged(SeekBar bar, int progress, boolean fromUser) {
                if (!fromUser || player == null) return;
                long duration = player.getDuration();
                if (duration > 0 && duration != C.TIME_UNSET) {
                    long position = duration * progress / 1000L;
                    time.setText(formatTime(position) + " / " + formatTime(duration));
                }
            }

            @Override public void onStartTrackingTouch(SeekBar bar) {
                dpadScrubbing = false;
                scrubbing = true;
                ui.removeCallbacks(hideControls);
            }

            @Override public void onStopTrackingTouch(SeekBar bar) {
                if (player != null) {
                    long duration = player.getDuration();
                    if (duration > 0 && duration != C.TIME_UNSET) {
                        player.seekTo(duration * bar.getProgress() / 1000L);
                    }
                }
                scrubbing = false;
                showControls();
            }
        });
        controls.addView(timeline, new LinearLayout.LayoutParams(-1, dp(22)));

        LinearLayout row = new LinearLayout(this);
        row.setGravity(Gravity.CENTER_VERTICAL);
        TextView rewind = controlButton("◀  −15 сек");
        playState = controlButton("▶");
        TextView forward = controlButton("+30 сек  ▶");
        settingsState = controlButton(settingsLabel());
        rewind.setOnClickListener(v -> seekBy(-15_000));
        playState.setOnClickListener(v -> togglePlayback());
        forward.setOnClickListener(v -> seekBy(30_000));
        settingsState.setContentDescription("Скорость и зеркальное отображение");
        settingsState.setOnClickListener(v -> setPlaybackMenuVisible(!playbackMenuVisible));
        row.addView(rewind, new LinearLayout.LayoutParams(0, dp(42), 1f));
        row.addView(playState, new LinearLayout.LayoutParams(0, dp(42), 0.65f));
        row.addView(forward, new LinearLayout.LayoutParams(0, dp(42), 1f));
        row.addView(settingsState, new LinearLayout.LayoutParams(0, dp(42),
                isCompactPlayer() ? 0.7f : 0.9f));
        controls.addView(row, new LinearLayout.LayoutParams(-1, dp(46)));

        controlsLayoutParams = new FrameLayout.LayoutParams(-1, dp(CONTROLS_HEIGHT_DP), Gravity.BOTTOM);
        applyControlsLayout();
        root.addView(controls, controlsLayoutParams);
        ViewCompat.setOnApplyWindowInsetsListener(root, (view, windowInsets) -> {
            Insets safe = windowInsets.getInsets(WindowInsetsCompat.Type.systemBars()
                    | WindowInsetsCompat.Type.displayCutout());
            safeLeft = safe.left;
            safeRight = safe.right;
            safeBottom = safe.bottom;
            applyControlsLayout();
            return windowInsets;
        });
        ViewCompat.requestApplyInsets(root);
        return root;
    }

    private TextView label(String value, int sp) {
        TextView label = new TextView(this);
        label.setText(value == null ? "" : value);
        label.setTextColor(Color.WHITE);
        label.setTextSize(sp);
        return label;
    }

    private TextView controlButton(String value) {
        TextView button = label(value, 15);
        button.setGravity(Gravity.CENTER);
        button.setBackgroundResource(R.drawable.filter_chip_background);
        button.setFocusable(true);
        return button;
    }

    private LinearLayout createPlaybackMenu() {
        LinearLayout menu = new LinearLayout(this);
        menu.setOrientation(LinearLayout.VERTICAL);
        menu.setVisibility(View.GONE);
        menu.setPadding(0, 0, 0, dp(8));

        TextView speedTitle = label("Скорость", isCompactPlayer() ? 12 : 14);
        speedTitle.setGravity(Gravity.CENTER_VERTICAL);
        menu.addView(speedTitle, new LinearLayout.LayoutParams(-1, dp(20)));

        LinearLayout speedRow = new LinearLayout(this);
        for (float speed : PLAYBACK_SPEEDS) {
            TextView option = settingsOption(speedLabel(speed));
            option.setTag(speed);
            option.setOnClickListener(view -> setPlaybackSpeed((Float) view.getTag()));
            speedOptions.add(option);
            LinearLayout.LayoutParams optionParams = new LinearLayout.LayoutParams(0, dp(34), 1f);
            optionParams.setMargins(dp(3), 0, dp(3), 0);
            speedRow.addView(option, optionParams);
        }
        menu.addView(speedRow, new LinearLayout.LayoutParams(-1, dp(36)));

        mirrorOptions = new LinearLayout(this);
        mirrorOptions.setGravity(Gravity.CENTER_VERTICAL);
        TextView mirrorTitle = label("Отображение", isCompactPlayer() ? 12 : 14);
        mirrorTitle.setGravity(Gravity.CENTER_VERTICAL);
        normalMirrorOption = settingsOption("Обычное");
        mirroredOption = settingsOption("Зеркальное");
        normalMirrorOption.setOnClickListener(view -> setMirrored(false));
        mirroredOption.setOnClickListener(view -> setMirrored(true));
        mirrorOptions.addView(mirrorTitle, new LinearLayout.LayoutParams(0, dp(34), 0.8f));
        LinearLayout.LayoutParams normalParams = new LinearLayout.LayoutParams(0, dp(34), 1f);
        normalParams.setMargins(dp(3), 0, dp(3), 0);
        mirrorOptions.addView(normalMirrorOption, normalParams);
        LinearLayout.LayoutParams mirroredParams = new LinearLayout.LayoutParams(0, dp(34), 1f);
        mirroredParams.setMargins(dp(3), 0, dp(3), 0);
        mirrorOptions.addView(mirroredOption, mirroredParams);
        mirrorOptions.setVisibility(audioOnly ? View.GONE : View.VISIBLE);
        menu.addView(mirrorOptions, new LinearLayout.LayoutParams(-1, dp(38)));
        updatePlaybackSettingsUi();
        return menu;
    }

    private TextView settingsOption(String value) {
        TextView option = controlButton(value);
        option.setTextSize(isCompactPlayer() ? 12 : 14);
        option.setPadding(dp(4), 0, dp(4), 0);
        return option;
    }

    private void resolveStream() {
        String url = getIntent().getStringExtra("resolver_url");
        resolver.execute(() -> {
            try {
                PlaybackInfo resolved = new StreamResolver().resolveForPlayback(url, audioOnly);
                runOnUiThread(() -> {
                    streamUrl = resolved.streamUrl;
                    streamMimeType = resolved.streamMimeType;
                    startPlayerSafely();
                });
            } catch (Exception error) {
                runOnUiThread(() -> showError(error.getMessage() == null ? "Видео больше недоступно" : error.getMessage()));
            }
        });
    }

    private void startPlayerSafely() {
        try {
            startPlayer();
        } catch (Throwable error) {
            CrashLog.save(getApplicationContext(), error);
            String detail = error.getClass().getSimpleName();
            if (error.getMessage() != null) detail += ": " + error.getMessage();
            showError("Сбой инициализации плеера: " + detail);
        }
    }

    @OptIn(markerClass = UnstableApi.class)
    private void startPlayer() {
        if (streamUrl == null || player != null) return;
        Map<String, String> headers = new HashMap<>();
        String source = getIntent().getStringExtra("source");
        boolean vk = "VK VIDEO".equals(source);
        boolean dzen = "ДЗЕН".equals(source);
        boolean ok = "OK".equals(source);
        if (dzen) {
            CookieHandler.setDefault(new CookieManager(null, CookiePolicy.ACCEPT_ALL));
        } else {
            if (ok) CookieHandler.setDefault(new CookieManager(null, CookiePolicy.ACCEPT_NONE));
            headers.put("Referer", vk ? "https://vkvideo.ru/"
                    : ok ? OkClient.REFERER : "https://rutube.ru/");
        }
        DefaultHttpDataSource.Factory http = new DefaultHttpDataSource.Factory()
                .setUserAgent(dzen ? DzenClient.USER_AGENT : vk
                        ? "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/150 Safari/537.36"
                        : ok ? OkClient.USER_AGENT
                        : "Mozilla/5.0 (Linux; Android 11; Android TV) AppleWebKit/537.36")
                .setConnectTimeoutMs(8_000)
                .setReadTimeoutMs(10_000)
                .setAllowCrossProtocolRedirects(true)
                .setDefaultRequestProperties(headers);
        DeviceCapabilities capabilities = DeviceCapabilities.get();
        MediaCodecSelector hardwareSelector = (mimeType, secure, tunneling) -> {
            List<MediaCodecInfo> available = MediaCodecSelector.DEFAULT.getDecoderInfos(mimeType, secure, tunneling);
            if (!mimeType.startsWith("video/") && !mimeType.startsWith("audio/")) return available;
            boolean video = mimeType.startsWith("video/");
            List<MediaCodecInfo> hardware = new ArrayList<>();
            for (MediaCodecInfo codec : available) {
                if (codec.hardwareAccelerated && !codec.softwareOnly) hardware.add(codec);
            }
            if (video) {
                return capabilities.supportsHardware(mimeType) ? hardware : new ArrayList<>();
            }
            // Some TV firmware advertises a hardware AAC decoder that accepts mono only.
            // Keep compatible software audio decoders after hardware candidates so Media3
            // can fall back for stereo tracks without ever allowing software video.
            List<MediaCodecInfo> ordered = new ArrayList<>(hardware);
            for (MediaCodecInfo codec : available) {
                if (!hardware.contains(codec)) ordered.add(codec);
            }
            return ordered;
        };
        player = new ExoPlayer.Builder(this)
                .setRenderersFactory(new DefaultRenderersFactory(this)
                        .setMediaCodecSelector(hardwareSelector)
                        .setEnableDecoderFallback(true))
                .setMediaSourceFactory(new DefaultMediaSourceFactory(http))
                .build();
        androidx.media3.common.TrackSelectionParameters.Builder tracks =
                player.getTrackSelectionParameters().buildUpon();
        String[] preferredVideo = capabilities.preferredVideoMimes(trafficMode);
        String[] preferredAudio = capabilities.preferredAudioMimes(trafficMode);
        if (preferredVideo.length > 0) tracks.setPreferredVideoMimeTypes(preferredVideo);
        if (preferredAudio.length > 0) tracks.setPreferredAudioMimeTypes(preferredAudio);
        if (trafficMode) {
            int[] size = videoSizeForHeight(targetHeight == 0 ? 144 : targetHeight);
            tracks.setMaxVideoSize(size[0], size[1])
                    .setForceHighestSupportedBitrate(!audioOnly)
                    .setForceLowestBitrate(audioOnly);
            if (audioOnly) {
                tracks.setMaxVideoBitrate(144_000)
                        .setTrackTypeDisabled(C.TRACK_TYPE_VIDEO, true);
                videoSurface.setVisibility(View.INVISIBLE);
            }
        } else {
            tracks.setMaxVideoSize(3840, 2160).setForceHighestSupportedBitrate(true);
        }
        player.setTrackSelectionParameters(tracks.build());
        player.setAudioAttributes(new AudioAttributes.Builder()
                .setUsage(C.USAGE_MEDIA)
                .setContentType(C.AUDIO_CONTENT_TYPE_MOVIE)
                .build(), true);
        videoSurface.setMirrored(mirrored);
        Surface output = videoSurface.getVideoSurface();
        if (output != null) player.setVideoSurface(output);
        player.addListener(new Player.Listener() {
            @Override public void onPlaybackStateChanged(int state) {
                if (state == Player.STATE_READY) {
                    loading.setVisibility(View.GONE);
                    message.setVisibility(View.GONE);
                    if (!autoPlay || audioOnly) showControls();
                } else if (state == Player.STATE_ENDED) {
                    showControls();
                }
            }

            @Override public void onIsPlayingChanged(boolean isPlaying) {
                updateControls();
                scheduleControlsHide();
            }

            @Override public void onVideoSizeChanged(VideoSize size) {
                videoWidth = size.width;
                videoHeight = size.height;
                fitSurface(size.width, size.height);
            }

            @Override public void onPlayerError(PlaybackException error) {
                showError("Ошибка воспроизведения: " + error.getErrorCodeName());
            }
        });
        MediaItem.Builder item = new MediaItem.Builder().setUri(streamUrl);
        if (streamMimeType != null) item.setMimeType(streamMimeType);
        else if (streamUrl.contains(".m3u8")) item.setMimeType(MimeTypes.APPLICATION_M3U8);
        else if (streamUrl.contains(".mpd")) item.setMimeType(MimeTypes.APPLICATION_MPD);
        player.setMediaItem(item.build());
        if (resumePosition > 0) player.seekTo(resumePosition);
        player.setPlaybackSpeed(playbackSpeed);
        player.setPlayWhenReady(autoPlay);
        player.prepare();
        ui.post(progressTicker);
    }

    private void showControls() {
        boolean wasHidden = controls.getVisibility() != View.VISIBLE;
        controls.animate().cancel();
        if (wasHidden) controls.setTranslationY(0f);
        controls.setVisibility(View.VISIBLE);
        updateControls();
        scheduleControlsHide();
    }

    private void scheduleControlsHide() {
        ui.removeCallbacks(hideControls);
        if (audioOnly || playbackMenuVisible || scrubbing || dpadScrubbing
                || controlsDragging || player == null
                || controls.getVisibility() != View.VISIBLE
                || player.getPlaybackState() == Player.STATE_ENDED) return;
        ui.postDelayed(hideControls, player.isPlaying()
                ? PLAYING_CONTROLS_TIMEOUT_MS : PAUSED_CONTROLS_TIMEOUT_MS);
    }

    private void updateControls() {
        if (player == null) return;
        long position = Math.max(0, player.getCurrentPosition());
        long duration = player.getDuration();
        if (!scrubbing) {
            long displayedPosition = dpadScrubbing ? dpadSeekPosition : position;
            if (duration <= 0 || duration == C.TIME_UNSET) {
                timeline.setProgress(0);
                time.setText(formatTime(displayedPosition) + " / —");
            } else {
                timeline.setProgress((int) Math.min(1000,
                        displayedPosition * 1000 / duration));
                time.setText(formatTime(displayedPosition) + " / " + formatTime(duration));
            }
        }
        playState.setText(player.isPlaying() ? "Ⅱ" : "▶");
        long now = System.currentTimeMillis();
        if (now - lastSavedAt > 5000) {
            StateStore.savePlayerPosition(this, position);
            saveWatchProgress(position, duration);
            lastSavedAt = now;
        }
    }

    private void togglePlayback() {
        if (player == null) return;
        boolean wasPlaying = player.isPlaying();
        commitDpadScrub();
        if (wasPlaying) player.pause(); else player.play();
        showControls();
    }

    private void seekBy(long deltaMs) {
        if (player == null) return;
        long target = Math.max(0, player.getCurrentPosition() + deltaMs);
        long duration = player.getDuration();
        if (duration > 0 && duration != C.TIME_UNSET) target = Math.min(target, duration);
        player.seekTo(target);
        showControls();
    }

    private void beginDpadScrub() {
        if (player == null) return;
        if (!dpadScrubbing) {
            dpadSeekPosition = Math.max(0L, player.getCurrentPosition());
            dpadScrubbing = true;
        }
        showControls();
        ui.removeCallbacks(hideControls);
    }

    private void moveDpadScrub(long deltaMs) {
        if (player == null) return;
        beginDpadScrub();
        long target = Math.max(0L, dpadSeekPosition + deltaMs);
        long duration = player.getDuration();
        if (duration > 0 && duration != C.TIME_UNSET) target = Math.min(target, duration);
        dpadSeekPosition = target;
        updateControls();
    }

    private void commitDpadScrub() {
        if (player == null || !dpadScrubbing) return;
        long position = dpadSeekPosition;
        dpadScrubbing = false;
        player.seekTo(position);
    }

    private static long seekDelta(int keyCode) {
        return keyCode == KeyEvent.KEYCODE_DPAD_LEFT ? -15_000L : 30_000L;
    }

    private boolean handleHorizontalDpad(KeyEvent event) {
        int keyCode = event.getKeyCode();
        if (keyCode != KeyEvent.KEYCODE_DPAD_LEFT
                && keyCode != KeyEvent.KEYCODE_DPAD_RIGHT) return false;
        if (player == null) return true;
        if (event.getAction() == KeyEvent.ACTION_DOWN) {
            if (event.getRepeatCount() == 0 || heldSeekKey != keyCode) {
                ui.removeCallbacks(beginHeldSeek);
                heldSeekKey = keyCode;
                heldSeekIsLong = false;
                ui.postDelayed(beginHeldSeek, ViewConfiguration.getLongPressTimeout());
            } else {
                if (!heldSeekIsLong) {
                    ui.removeCallbacks(beginHeldSeek);
                    heldSeekIsLong = true;
                    beginDpadScrub();
                    moveDpadScrub(seekDelta(keyCode));
                } else {
                    moveDpadScrub(seekDelta(keyCode));
                }
            }
            return true;
        }
        if (event.getAction() == KeyEvent.ACTION_UP && heldSeekKey == keyCode) {
            ui.removeCallbacks(beginHeldSeek);
            if (!heldSeekIsLong) {
                if (dpadScrubbing) moveDpadScrub(seekDelta(keyCode));
                else seekBy(seekDelta(keyCode));
            } else {
                commitDpadScrub();
                showControls();
            }
            heldSeekKey = KeyEvent.KEYCODE_UNKNOWN;
            heldSeekIsLong = false;
            return true;
        }
        return true;
    }

    private void setMirrored(boolean value) {
        if (audioOnly || mirrored == value) return;
        mirrored = value;
        videoSurface.setMirrored(mirrored);
        saveMirrorState();
        updatePlaybackSettingsUi();
    }

    private void setPlaybackSpeed(float speed) {
        playbackSpeed = normalizedPlaybackSpeed(speed);
        StateStore.savePlaybackSpeed(this, playbackSpeed);
        if (player != null) player.setPlaybackSpeed(playbackSpeed);
        updatePlaybackSettingsUi();
    }

    private void setPlaybackMenuVisible(boolean visible) {
        if (playbackMenu == null || settingsState == null) return;
        playbackMenuVisible = visible;
        playbackMenu.setVisibility(visible ? View.VISIBLE : View.GONE);
        settingsState.setSelected(visible);
        controlsLayoutParams.height = dp(CONTROLS_HEIGHT_DP
                + (visible ? playbackMenuHeightDp() : 0));
        controls.setLayoutParams(controlsLayoutParams);
        if (visible) {
            showControls();
            TextView selected = selectedSpeedOption();
            if (DeviceType.isTelevision(this) && selected != null) selected.requestFocus();
        } else {
            controls.clearFocus();
            scheduleControlsHide();
        }
    }

    private void updatePlaybackSettingsUi() {
        if (settingsState != null) settingsState.setText(settingsLabel());
        for (TextView option : speedOptions) {
            Object tag = option.getTag();
            option.setSelected(tag instanceof Float
                    && Math.abs((Float) tag - playbackSpeed) < 0.001f);
        }
        if (normalMirrorOption != null) normalMirrorOption.setSelected(!mirrored);
        if (mirroredOption != null) mirroredOption.setSelected(mirrored);
    }

    private TextView selectedSpeedOption() {
        for (TextView option : speedOptions) {
            if (option.isSelected()) return option;
        }
        return speedOptions.isEmpty() ? null : speedOptions.get(0);
    }

    private String settingsLabel() {
        return "⚙  " + speedLabel(playbackSpeed) + (mirrored && !audioOnly ? "  ↔" : "");
    }

    private int playbackMenuHeightDp() {
        return audioOnly ? 64 : 102;
    }

    private static float normalizedPlaybackSpeed(float speed) {
        for (float supported : PLAYBACK_SPEEDS) {
            if (Math.abs(supported - speed) < 0.01f) return supported;
        }
        return 1f;
    }

    private static String speedLabel(float speed) {
        if (Math.abs(speed - 1f) < 0.001f) return "1×";
        if (Math.abs(speed - 2f) < 0.001f) return "2×";
        if (Math.abs(speed - 0.75f) < 0.001f) return "0,75×";
        if (Math.abs(speed - 1.25f) < 0.001f) return "1,25×";
        return "1,5×";
    }

    private static int[] videoSizeForHeight(int height) {
        switch (height) {
            case 720: return new int[]{1280, 720};
            case 480: return new int[]{854, 480};
            case 360: return new int[]{640, 360};
            case 240: return new int[]{426, 240};
            default: return new int[]{256, 144};
        }
    }

    private static String formatTime(long millis) {
        long total = Math.max(0, millis / 1000);
        long hours = total / 3600;
        long minutes = total % 3600 / 60;
        long seconds = total % 60;
        return hours > 0 ? String.format(Locale.ROOT, "%d:%02d:%02d", hours, minutes, seconds)
                : String.format(Locale.ROOT, "%d:%02d", minutes, seconds);
    }

    private void fitSurface(int width, int height) {
        if (width <= 0 || height <= 0) return;
        int screenW = getResources().getDisplayMetrics().widthPixels;
        int screenH = getResources().getDisplayMetrics().heightPixels;
        float ratio = Math.min(screenW / (float) width, screenH / (float) height);
        videoSurface.setLayoutParams(new FrameLayout.LayoutParams(
                Math.round(width * ratio), Math.round(height * ratio), Gravity.CENTER));
    }

    private boolean isCompactPlayer() {
        float widthDp = getResources().getDisplayMetrics().widthPixels
                / getResources().getDisplayMetrics().density;
        return getResources().getConfiguration().orientation == Configuration.ORIENTATION_PORTRAIT
                || widthDp < 720;
    }

    private void applyControlsLayout() {
        if (controlsLayoutParams == null) return;
        int horizontal = isCompactPlayer() ? 10 : 28;
        int bottom = isCompactPlayer() ? 10 : 24;
        controlsLayoutParams.setMargins(dp(horizontal) + safeLeft, 0,
                dp(horizontal) + safeRight, dp(bottom) + safeBottom);
        if (controls != null) controls.setLayoutParams(controlsLayoutParams);
    }

    private final class DraggableControlsLayout extends LinearLayout {
        private final int touchSlop;
        private float downX;
        private float downY;
        private float startTranslation;
        private boolean dragging;

        DraggableControlsLayout() {
            super(PlayerActivity.this);
            touchSlop = ViewConfiguration.get(PlayerActivity.this).getScaledTouchSlop();
        }

        @Override public boolean onInterceptTouchEvent(MotionEvent event) {
            switch (event.getActionMasked()) {
                case MotionEvent.ACTION_DOWN:
                    beginGesture(event);
                    return false;
                case MotionEvent.ACTION_MOVE:
                    return startDraggingIfNeeded(event);
                case MotionEvent.ACTION_UP:
                case MotionEvent.ACTION_CANCEL:
                    controlsDragging = false;
                    scheduleControlsHide();
                    return false;
                default:
                    return false;
            }
        }

        @Override public boolean onTouchEvent(MotionEvent event) {
            switch (event.getActionMasked()) {
                case MotionEvent.ACTION_DOWN:
                    beginGesture(event);
                    return true;
                case MotionEvent.ACTION_MOVE:
                    if (!startDraggingIfNeeded(event)) return true;
                    moveWithFinger(event.getRawY() - downY);
                    return true;
                case MotionEvent.ACTION_UP:
                case MotionEvent.ACTION_CANCEL:
                    if (!dragging) {
                        controlsDragging = false;
                        scheduleControlsHide();
                        return true;
                    }
                    dragging = false;
                    controlsDragging = false;
                    getParent().requestDisallowInterceptTouchEvent(false);
                    animate().translationY(0f)
                            .setDuration(240L)
                            .setInterpolator(new OvershootInterpolator(0.6f))
                            .withLayer()
                            .withEndAction(PlayerActivity.this::scheduleControlsHide)
                            .start();
                    return true;
                default:
                    return true;
            }
        }

        private void beginGesture(MotionEvent event) {
            downX = event.getRawX();
            downY = event.getRawY();
            startTranslation = getTranslationY();
            dragging = false;
            animate().cancel();
            ui.removeCallbacks(hideControls);
        }

        private boolean startDraggingIfNeeded(MotionEvent event) {
            if (dragging) return true;
            float dx = event.getRawX() - downX;
            float dy = event.getRawY() - downY;
            if (Math.abs(dy) <= touchSlop || Math.abs(dy) <= Math.abs(dx)) return false;
            dragging = true;
            controlsDragging = true;
            getParent().requestDisallowInterceptTouchEvent(true);
            return true;
        }

        private void moveWithFinger(float distance) {
            float translation = startTranslation + distance;
            float minimum = -getTop();
            float maximum = ((View) getParent()).getHeight() - getBottom();
            setTranslationY(Math.max(minimum, Math.min(maximum, translation)));
        }
    }

    @Override public void onConfigurationChanged(Configuration configuration) {
        super.onConfigurationChanged(configuration);
        applyControlsLayout();
        if (videoWidth > 0 && videoHeight > 0) fitSurface(videoWidth, videoHeight);
    }

    private void showError(String text) {
        loading.setVisibility(View.GONE);
        controls.setVisibility(View.GONE);
        message.setVisibility(View.VISIBLE);
        message.setText(text + "\n\nOK — открыть официальный плеер");
    }

    @Override public boolean dispatchKeyEvent(KeyEvent event) {
        int keyCode = event.getKeyCode();
        if (DeviceType.isTelevision(this) && !playbackMenuVisible
                && keyCode == KeyEvent.KEYCODE_DPAD_DOWN) {
            if (event.getAction() == KeyEvent.ACTION_DOWN && event.getRepeatCount() == 0) {
                openHistory();
            }
            return true;
        }
        if (keyCode == KeyEvent.KEYCODE_MENU) {
            if (event.getAction() == KeyEvent.ACTION_DOWN && event.getRepeatCount() == 0) {
                setPlaybackMenuVisible(!playbackMenuVisible);
            }
            return true;
        }
        boolean centerKey = keyCode == KeyEvent.KEYCODE_DPAD_CENTER
                || keyCode == KeyEvent.KEYCODE_ENTER;
        if (centerKey && (centerKeyHeld || !playbackMenuVisible)) {
            if (event.getAction() == KeyEvent.ACTION_DOWN) {
                if (event.getRepeatCount() == 0) {
                    centerKeyHeld = true;
                    centerLongPressTriggered = false;
                    ui.postDelayed(openMenuFromLongCenter,
                            ViewConfiguration.getLongPressTimeout());
                }
                return true;
            }
            if (event.getAction() == KeyEvent.ACTION_UP) {
                ui.removeCallbacks(openMenuFromLongCenter);
                centerKeyHeld = false;
                if (!centerLongPressTriggered) {
                    if (player != null && player.getPlaybackState() != Player.STATE_IDLE) {
                        togglePlayback();
                    } else {
                        openOfficial();
                    }
                }
                centerLongPressTriggered = false;
                return true;
            }
        }
        if (playbackMenuVisible) return super.dispatchKeyEvent(event);
        if (handleHorizontalDpad(event)) return true;
        return super.dispatchKeyEvent(event);
    }

    @Override public boolean onKeyDown(int keyCode, KeyEvent event) {
        if (keyCode == KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE) {
            if (player != null && player.getPlaybackState() != Player.STATE_IDLE) {
                togglePlayback();
            } else openOfficial();
            return true;
        }
        if (keyCode == KeyEvent.KEYCODE_DPAD_UP) {
            showControls();
            return true;
        }
        return super.onKeyDown(keyCode, event);
    }

    @Override public void onBackPressed() {
        if (playbackMenuVisible) {
            setPlaybackMenuVisible(false);
            return;
        }
        leavingPlayer = true;
        saveProgress();
        StateStore.markReturnScreen(this);
        super.onBackPressed();
    }

    private void saveProgress() {
        saveMirrorState();
        if (player != null) {
            long position = player.getCurrentPosition();
            StateStore.savePlayerPosition(this, position);
            saveWatchProgress(position, player.getDuration());
        }
    }

    private void saveMirrorState() {
        if (!audioOnly) {
            WatchProgressStore.setMirrored(this, videoSource, videoIdentityUrl, mirrored);
        }
    }

    private void saveWatchProgress(long position, long duration) {
        long actualDuration = duration > 0 && duration != androidx.media3.common.C.TIME_UNSET
                ? duration : knownDuration;
        if (actualDuration > 0) knownDuration = actualDuration;
        WatchProgressStore.save(this,
                getIntent().getStringExtra("source"),
                getIntent().getStringExtra("page_url"),
                Math.max(0L, position),
                Math.max(0L, actualDuration));
        if (!historyRecordedThisSession && position >= WatchProgressStore.MIN_POSITION_MS) {
            WatchHistoryStore.record(this, historyItem.withDuration(actualDuration),
                    trafficMode, targetHeight, audioOnly);
            historyRecordedThisSession = true;
        }
    }

    private void openOfficial() {
        String page = getIntent().getStringExtra("page_url");
        if (page == null) return;
        try { startActivity(new Intent(Intent.ACTION_VIEW, Uri.parse(page))); } catch (Exception ignored) { }
    }

    private void openHistory() {
        leavingPlayer = true;
        saveProgress();
        StateStore.markHistory(this);
        finish();
    }

    @Override protected void onStart() {
        super.onStart();
        if (audioMovedToBackground) {
            stopService(new Intent(this, AudioPlaybackService.class));
            if (player != null) {
                player.seekTo(StateStore.position(this));
                player.play();
            }
            audioMovedToBackground = false;
        }
        if (player != null && !player.isPlaying()) showControls();
    }

    @Override protected void onResume() {
        super.onResume();
        if (videoSurface != null) videoSurface.onResume();
    }

    @Override protected void onPause() {
        if (videoSurface != null) videoSurface.onPause();
        super.onPause();
    }

    @Override protected void onStop() {
        saveProgress();
        if (player != null) {
            boolean keepAudio = audioOnly && !DeviceType.isTelevision(this)
                    && player.isPlaying() && streamUrl != null && !leavingPlayer && !isFinishing();
            player.pause();
            if (keepAudio) startBackgroundAudio();
        }
        super.onStop();
    }

    private void startBackgroundAudio() {
        Intent background = new Intent(this, AudioPlaybackService.class)
                .setAction(AudioPlaybackService.ACTION_PLAY);
        if (getIntent().getExtras() != null) background.putExtras(getIntent().getExtras());
        background.putExtra("stream_url", streamUrl);
        background.putExtra("stream_mime_type", streamMimeType);
        background.putExtra("resume_position", player == null ? 0L : player.getCurrentPosition());
        background.putExtra("duration_ms", knownDuration);
        background.putExtra("playback_speed", playbackSpeed);
        try {
            ContextCompat.startForegroundService(this, background);
            audioMovedToBackground = true;
        } catch (RuntimeException ignored) {
            audioMovedToBackground = false;
        }
    }

    private void requestNotificationPermissionForAudio() {
        if (!audioOnly || DeviceType.isTelevision(this) || Build.VERSION.SDK_INT < 33) return;
        if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)
                != android.content.pm.PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS}, 5803);
        }
    }

    @Override protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        if (!intent.getBooleanExtra("resume_background_audio", false)) return;
        stopService(new Intent(this, AudioPlaybackService.class));
        if (player != null) {
            player.seekTo(StateStore.position(this));
            player.play();
            showControls();
        }
        audioMovedToBackground = false;
    }

    @Override protected void onDestroy() {
        resolver.shutdownNow();
        ui.removeCallbacksAndMessages(null);
        releasePlayer();
        if (videoSurface != null) videoSurface.release();
        if (Thread.getDefaultUncaughtExceptionHandler() != previousCrashHandler) {
            Thread.setDefaultUncaughtExceptionHandler(previousCrashHandler);
        }
        super.onDestroy();
    }

    private void releasePlayer() {
        if (player == null) return;
        player.clearVideoSurface();
        player.release();
        player = null;
    }

    private int dp(int value) { return Math.round(value * getResources().getDisplayMetrics().density); }
}
