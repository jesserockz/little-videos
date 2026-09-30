package io.github.jesserockz.littlevideos;

import android.app.Activity;
import android.media.MediaPlayer;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.view.View;
import android.widget.ImageButton;
import android.widget.ProgressBar;
import android.widget.VideoView;

import java.util.List;

/** Fullscreen player with tap-to-reveal controls and no seeking. */
public class PlayerActivity extends Activity {
    public static final String EXTRA_INDEX = "index";

    private static final long HIDE_DELAY_MS = 3500;
    private static final long PROGRESS_INTERVAL_MS = 250;
    private static final float DISABLED_ALPHA = 0.3f;

    private final Handler handler = new Handler(Looper.getMainLooper());
    private Prefs prefs;
    private List<VideoItem> items;
    private int index;

    private View root;
    private VideoView video;
    private View overlay;
    private View errorPanel;
    private ProgressBar progress;
    private ImageButton btnPlay;
    private ImageButton btnPrev;
    private ImageButton btnNext;

    private boolean prepared = false;
    private boolean wantPlay = true;
    private boolean errorShown = false;
    private int resumePos = 0;

    private final Runnable hideRunnable = new Runnable() {
        @Override
        public void run() {
            hideControls();
        }
    };

    private final Runnable progressRunnable = new Runnable() {
        @Override
        public void run() {
            if (prepared && !errorShown) {
                try {
                    int dur = video.getDuration();
                    if (dur > 0) {
                        progress.setProgress((int) (video.getCurrentPosition() * 1000L / dur));
                    }
                } catch (RuntimeException ignored) {
                    // player in a transient state; try again next tick
                }
            }
            handler.postDelayed(this, PROGRESS_INTERVAL_MS);
        }
    };

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        prefs = new Prefs(this);
        items = VideoLibrary.current();
        index = getIntent().getIntExtra(EXTRA_INDEX, 0);
        if (savedInstanceState != null) {
            index = savedInstanceState.getInt("index", index);
            resumePos = savedInstanceState.getInt("pos", 0);
            wantPlay = savedInstanceState.getBoolean("playing", true);
        }
        if (items.isEmpty() || index < 0 || index >= items.size()) {
            finish();
            return;
        }

        setContentView(R.layout.activity_player);
        root = findViewById(R.id.player_root);
        video = (VideoView) findViewById(R.id.video);
        overlay = findViewById(R.id.overlay);
        errorPanel = findViewById(R.id.error_panel);
        progress = (ProgressBar) findViewById(R.id.progress);
        btnPlay = (ImageButton) findViewById(R.id.btn_play);
        btnPrev = (ImageButton) findViewById(R.id.btn_prev);
        btnNext = (ImageButton) findViewById(R.id.btn_next);
        Ui.applyInsets(overlay);

        // Screen-on without needing the WAKE_LOCK permission.
        root.setKeepScreenOn(true);

        // No MediaController on purpose: nothing here can scrub.
        root.setOnClickListener(v -> showControls());
        findViewById(R.id.btn_back).setOnClickListener(v -> finish());
        findViewById(R.id.error_button).setOnClickListener(v -> finish());
        btnPlay.setOnClickListener(v -> {
            togglePlay();
            scheduleHide();
        });
        btnPrev.setOnClickListener(v -> {
            if (index > 0) {
                loadVideo(index - 1, 0, true);
            }
            scheduleHide();
        });
        btnNext.setOnClickListener(v -> {
            if (index + 1 < items.size()) {
                loadVideo(index + 1, 0, true);
            }
            scheduleHide();
        });
        findViewById(R.id.btn_replay).setOnClickListener(v -> {
            if (prepared) {
                video.seekTo(0);
                video.start();
                wantPlay = true;
                updatePlayIcon();
            }
            scheduleHide();
        });

        video.setOnPreparedListener(new MediaPlayer.OnPreparedListener() {
            @Override
            public void onPrepared(MediaPlayer mp) {
                prepared = true;
                mp.setLooping(false);
            }
        });
        video.setOnCompletionListener(mp -> onCompleted());
        video.setOnErrorListener((mp, what, extra) -> {
            showError();
            return true; // handled: suppresses the framework's raw error dialog
        });
    }

    @Override
    protected void onResume() {
        super.onResume();
        Ui.applyImmersive(this);
        if (items.isEmpty() || isFinishing()) {
            return;
        }
        // The surface is destroyed while stopped, so reopen at the remembered position.
        if (!errorShown) {
            loadVideo(index, resumePos, wantPlay);
        }
        handler.removeCallbacks(progressRunnable);
        handler.post(progressRunnable);
    }

    @Override
    protected void onPause() {
        handler.removeCallbacks(hideRunnable);
        handler.removeCallbacks(progressRunnable);
        if (video != null && !errorShown) {
            if (prepared) {
                resumePos = video.getCurrentPosition();
            }
            try {
                video.pause();
            } catch (RuntimeException ignored) {
                // ignore
            }
        }
        super.onPause();
    }

    @Override
    protected void onSaveInstanceState(Bundle outState) {
        super.onSaveInstanceState(outState);
        outState.putInt("index", index);
        outState.putInt("pos", resumePos);
        outState.putBoolean("playing", wantPlay);
    }

    @Override
    protected void onDestroy() {
        handler.removeCallbacksAndMessages(null);
        if (overlay != null) {
            overlay.animate().cancel();
        }
        if (video != null) {
            video.setOnPreparedListener(null);
            video.setOnCompletionListener(null);
            video.setOnErrorListener(null);
            video.stopPlayback();
        }
        super.onDestroy();
    }

    @Override
    public void onWindowFocusChanged(boolean hasFocus) {
        super.onWindowFocusChanged(hasFocus);
        if (hasFocus) {
            Ui.applyImmersive(this);
        }
    }

    /** Loads a video in place (no new activity). startMs is applied once the player is prepared. */
    private void loadVideo(int newIndex, int startMs, boolean autoPlay) {
        index = newIndex;
        prepared = false;
        wantPlay = autoPlay;
        resumePos = startMs;
        progress.setProgress(0);
        errorShown = false;
        errorPanel.setVisibility(View.GONE);
        video.setVisibility(View.VISIBLE);
        try {
            video.setVideoURI(items.get(newIndex).uri);
            if (startMs > 0) {
                video.seekTo(startMs);
            }
            if (autoPlay) {
                video.start();
            }
        } catch (Throwable t) {
            showError();
            return;
        }
        updatePlayIcon();
        updateNavState();
    }

    private void togglePlay() {
        if (!prepared) {
            wantPlay = !wantPlay;
            if (wantPlay) {
                video.start();
            }
        } else if (video.isPlaying()) {
            video.pause();
            wantPlay = false;
        } else {
            video.start();
            wantPlay = true;
        }
        updatePlayIcon();
    }

    private void updatePlayIcon() {
        btnPlay.setImageResource(wantPlay ? R.drawable.ic_pause : R.drawable.ic_play);
        btnPlay.setContentDescription(getString(wantPlay ? R.string.player_pause : R.string.player_play));
    }

    private void updateNavState() {
        setEnabledLook(btnPrev, index > 0);
        setEnabledLook(btnNext, index + 1 < items.size());
    }

    private static void setEnabledLook(ImageButton b, boolean enabled) {
        b.setAlpha(enabled ? 1f : DISABLED_ALPHA);
        b.setClickable(enabled);
        b.setEnabled(enabled);
    }

    private void onCompleted() {
        switch (prefs.getOnEnd()) {
            case Prefs.END_NEXT:
                if (index + 1 < items.size()) {
                    loadVideo(index + 1, 0, true);
                } else {
                    finish();
                }
                break;
            case Prefs.END_REPEAT:
                video.seekTo(0);
                video.start();
                wantPlay = true;
                updatePlayIcon();
                break;
            case Prefs.END_GRID:
            default:
                finish();
                break;
        }
    }

    private void showError() {
        errorShown = true;
        prepared = false;
        handler.removeCallbacks(hideRunnable);
        overlay.animate().cancel();
        overlay.setVisibility(View.GONE);
        try {
            video.stopPlayback();
        } catch (RuntimeException ignored) {
            // ignore
        }
        video.setVisibility(View.INVISIBLE);
        errorPanel.setVisibility(View.VISIBLE);
    }

    private void showControls() {
        if (errorShown) {
            return;
        }
        overlay.animate().cancel();
        overlay.setVisibility(View.VISIBLE);
        overlay.animate().alpha(1f).setDuration(150).start();
        scheduleHide();
    }

    private void scheduleHide() {
        handler.removeCallbacks(hideRunnable);
        handler.postDelayed(hideRunnable, HIDE_DELAY_MS);
    }

    private void hideControls() {
        overlay.animate().cancel();
        // Once faded out the overlay goes GONE so a stray tap can never hit an invisible button.
        overlay.animate().alpha(0f).setDuration(300).withEndAction(() -> {
            if (overlay.getAlpha() == 0f) {
                overlay.setVisibility(View.GONE);
            }
        }).start();
    }
}
