package io.github.jesserockz.littlevideos;

import android.app.Activity;
import android.content.pm.ActivityInfo;
import android.media.MediaPlayer;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.view.LayoutInflater;
import android.view.MotionEvent;
import android.view.OrientationEventListener;
import android.view.Surface;
import android.view.View;
import android.view.ViewGroup;
import android.widget.HorizontalScrollView;
import android.widget.ImageButton;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.TextView;
import android.widget.VideoView;

import java.util.List;

/** Fullscreen player with tap-to-reveal controls and no seeking. */
public class PlayerActivity extends Activity {
    public static final String EXTRA_INDEX = "index";

    private static final long HIDE_DELAY_MS = 3500;
    private static final long PROGRESS_INTERVAL_MS = 250;
    private static final float DISABLED_ALPHA = 0.3f;
    private static final int MATCH_TOLERANCE_DEG = 30;
    private static final long CAROUSEL_HIDE_MS = 8000;
    private static final long CAROUSEL_ANIM_MS = 200;
    private static final float ZONE_FRACTION = 0.3f;
    private static final int SWIPE_DP = 48;
    private static final float SWIPE_RATIO = 1.5f;

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

    private View carouselLayer;
    private View carouselScrim;
    private View carouselPanel;
    private HorizontalScrollView carouselScroll;
    private LinearLayout carouselRow;
    private boolean[] carouselBound = new boolean[0];
    private boolean carouselShowing = false;
    private boolean gestureConsumed = false;
    private boolean downInZone = false;
    private boolean downInPanel = false;
    private float downX;
    private float downY;

    private boolean prepared = false;
    private boolean wantPlay = true;
    private boolean errorShown = false;
    private int resumePos = 0;
    private boolean rotationUnlocked = false;
    private OrientationEventListener orientationListener;

    private final Runnable hideRunnable = new Runnable() {
        @Override
        public void run() {
            hideControls();
        }
    };

    private final Runnable carouselHideRunnable = new Runnable() {
        @Override
        public void run() {
            closeCarousel(true);
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
            rotationUnlocked = savedInstanceState.getBoolean("rotationUnlocked", false);
        }
        if (items.isEmpty() || index < 0 || index >= items.size()) {
            finish();
            return;
        }

        // The manifest starts us in landscape; once restored as unlocked, rotate freely.
        if (rotationUnlocked) {
            setRequestedOrientation(ActivityInfo.SCREEN_ORIENTATION_FULL_SENSOR);
        }
        orientationListener = new OrientationEventListener(this) {
            @Override
            public void onOrientationChanged(int degrees) {
                onDeviceOrientation(degrees);
            }
        };

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
        carouselLayer = findViewById(R.id.carousel_layer);
        carouselScrim = findViewById(R.id.carousel_scrim);
        carouselPanel = findViewById(R.id.carousel_panel);
        carouselScroll = (HorizontalScrollView) findViewById(R.id.carousel_scroll);
        carouselRow = (LinearLayout) findViewById(R.id.carousel_row);
        Ui.applyInsets(carouselPanel);
        carouselScrim.setOnClickListener(v -> closeCarousel(true));
        carouselScroll.setOnScrollChangeListener((v, x, y, ox, oy) -> {
            scheduleCarouselHide();
            bindVisibleThumbs();
        });

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
        if (!rotationUnlocked && orientationListener.canDetectOrientation()) {
            orientationListener.enable();
        }
    }

    @Override
    protected void onPause() {
        if (orientationListener != null) {
            orientationListener.disable();
        }
        handler.removeCallbacks(hideRunnable);
        handler.removeCallbacks(progressRunnable);
        if (carouselShowing) {
            closeCarousel(false);
        }
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
        outState.putBoolean("rotationUnlocked", rotationUnlocked);
    }

    @Override
    protected void onDestroy() {
        handler.removeCallbacksAndMessages(null);
        if (overlay != null) {
            overlay.animate().cancel();
        }
        if (carouselPanel != null) {
            carouselPanel.animate().cancel();
            carouselScrim.animate().cancel();
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

    @Override
    public boolean dispatchTouchEvent(MotionEvent ev) {
        if (carouselLayer == null) {
            return super.dispatchTouchEvent(ev);
        }
        int action = ev.getActionMasked();
        if (action == MotionEvent.ACTION_DOWN) {
            gestureConsumed = false;
            downX = ev.getRawX();
            downY = ev.getRawY();
            downInZone = downY > root.getHeight() * (1f - ZONE_FRACTION);
            downInPanel = carouselShowing && insidePanel(downX, downY);
        }
        if (gestureConsumed) {
            if (action == MotionEvent.ACTION_UP || action == MotionEvent.ACTION_CANCEL) {
                gestureConsumed = false;
            }
            return true;
        }
        if (carouselShowing) {
            scheduleCarouselHide();
        }
        if (action == MotionEvent.ACTION_MOVE && (carouselShowing ? downInPanel : downInZone)) {
            float dy = ev.getRawY() - downY;
            float dx = ev.getRawX() - downX;
            int min = Ui.dp(this, SWIPE_DP);
            boolean steep = Math.abs(dy) > SWIPE_RATIO * Math.abs(dx);
            if (steep && (carouselShowing ? dy > min : dy < -min)) {
                if (carouselShowing) {
                    closeCarousel(true);
                } else {
                    openCarousel();
                }
                gestureConsumed = true;
                MotionEvent cancel = MotionEvent.obtain(ev);
                cancel.setAction(MotionEvent.ACTION_CANCEL);
                super.dispatchTouchEvent(cancel);
                cancel.recycle();
                return true;
            }
        }
        return super.dispatchTouchEvent(ev);
    }

    @Override
    public void onBackPressed() {
        if (carouselShowing) {
            closeCarousel(true);
        } else {
            super.onBackPressed();
        }
    }

    private boolean insidePanel(float rawX, float rawY) {
        int[] loc = new int[2];
        carouselPanel.getLocationOnScreen(loc);
        return rawX >= loc[0] && rawX <= loc[0] + carouselPanel.getWidth()
                && rawY >= loc[1] && rawY <= loc[1] + carouselPanel.getHeight();
    }

    private void openCarousel() {
        handler.removeCallbacks(hideRunnable);
        overlay.animate().cancel();
        overlay.setVisibility(View.GONE);
        carouselPanel.animate().cancel();
        carouselScrim.animate().cancel();
        carouselShowing = true;
        buildCarousel();
        carouselLayer.setVisibility(View.VISIBLE);
        carouselScrim.setAlpha(0f);
        carouselScrim.animate().alpha(1f).setDuration(CAROUSEL_ANIM_MS).start();
        carouselPanel.setTranslationY(root.getHeight());
        carouselPanel.animate().translationY(0f).setDuration(CAROUSEL_ANIM_MS).start();
        carouselScroll.post(() -> {
            View cur = carouselRow.getChildAt(index);
            if (cur != null) {
                int center = carouselRow.getLeft() + cur.getLeft() + cur.getWidth() / 2;
                carouselScroll.scrollTo(Math.max(0, center - carouselScroll.getWidth() / 2), 0);
            }
            bindVisibleThumbs();
        });
        scheduleCarouselHide();
    }

    private void closeCarousel(boolean animate) {
        handler.removeCallbacks(carouselHideRunnable);
        if (!carouselShowing) {
            return;
        }
        carouselShowing = false;
        carouselPanel.animate().cancel();
        carouselScrim.animate().cancel();
        if (!animate) {
            carouselLayer.setVisibility(View.GONE);
            return;
        }
        carouselScrim.animate().alpha(0f).setDuration(CAROUSEL_ANIM_MS).start();
        carouselPanel.animate().translationY(carouselPanel.getHeight()).setDuration(CAROUSEL_ANIM_MS)
                .withEndAction(() -> {
                    if (!carouselShowing) {
                        carouselLayer.setVisibility(View.GONE);
                    }
                }).start();
    }

    private void scheduleCarouselHide() {
        handler.removeCallbacks(carouselHideRunnable);
        handler.postDelayed(carouselHideRunnable, CAROUSEL_HIDE_MS);
    }

    private void buildCarousel() {
        carouselRow.removeAllViews();
        carouselBound = new boolean[items.size()];
        int cardW = getResources().getDimensionPixelSize(R.dimen.carousel_card_width);
        int gap = getResources().getDimensionPixelSize(R.dimen.carousel_spacing);
        LayoutInflater inflater = LayoutInflater.from(this);
        for (int i = 0; i < items.size(); i++) {
            final int pos = i;
            VideoItem item = items.get(i);
            View cell = inflater.inflate(R.layout.item_carousel, carouselRow, false);
            LinearLayout.LayoutParams clp = new LinearLayout.LayoutParams(cardW, ViewGroup.LayoutParams.WRAP_CONTENT);
            clp.setMarginEnd(i == items.size() - 1 ? 0 : gap);
            cell.setLayoutParams(clp);
            View card = cell.findViewById(R.id.card);
            card.setClipToOutline(true);
            card.getLayoutParams().height = cardW * 9 / 16;
            ((ImageView) cell.findViewById(R.id.thumb)).setImageResource(R.drawable.ic_film_placeholder);
            TextView title = (TextView) cell.findViewById(R.id.title);
            if (prefs.getShowTitles()) {
                title.setText(item.title);
            } else {
                title.setVisibility(View.GONE);
            }
            if (pos == index) {
                card.setForeground(getDrawable(R.drawable.fg_card_current));
                cell.setContentDescription(item.title + ", " + getString(R.string.player_carousel_current));
            } else {
                cell.setContentDescription(item.title);
            }
            cell.setOnClickListener(v -> {
                closeCarousel(true);
                if (pos != index) {
                    loadVideo(pos, 0, true);
                }
            });
            carouselRow.addView(cell);
        }
    }

    /** Binds thumbnails only for cards within one screen width of the visible window. */
    private void bindVisibleThumbs() {
        int w = carouselScroll.getWidth();
        int from = carouselScroll.getScrollX() - w;
        int to = carouselScroll.getScrollX() + 2 * w;
        int cardW = getResources().getDimensionPixelSize(R.dimen.carousel_card_width);
        int cardH = cardW * 9 / 16;
        for (int i = 0; i < carouselBound.length; i++) {
            if (carouselBound[i]) {
                continue;
            }
            View cell = carouselRow.getChildAt(i);
            int left = carouselRow.getLeft() + cell.getLeft();
            if (left + cell.getWidth() < from || left > to) {
                continue;
            }
            carouselBound[i] = true;
            final VideoItem item = items.get(i);
            final ImageView thumb = (ImageView) cell.findViewById(R.id.thumb);
            final TextView duration = (TextView) cell.findViewById(R.id.duration);
            ThumbnailLoader.get(this).load(item, thumb, cardW, cardH, () -> bindDuration(duration, item));
            bindDuration(duration, item);
        }
    }

    private static void bindDuration(TextView duration, VideoItem item) {
        if (item.durationMs > 0) {
            duration.setText(Ui.formatDuration(item.durationMs));
            duration.setVisibility(View.VISIBLE);
        } else {
            duration.setVisibility(View.GONE);
        }
    }

    /**
     * Stays landscape (even if held portrait) until the device is physically turned to match the
     * landscape screen once, then allows all four rotations regardless of the rotation lock.
     */
    private void onDeviceOrientation(int degrees) {
        if (degrees == OrientationEventListener.ORIENTATION_UNKNOWN || rotationUnlocked) {
            return;
        }
        int shown;
        switch (getWindowManager().getDefaultDisplay().getRotation()) {
            case Surface.ROTATION_90:
                shown = 90;
                break;
            case Surface.ROTATION_180:
                shown = 180;
                break;
            case Surface.ROTATION_270:
                shown = 270;
                break;
            case Surface.ROTATION_0:
            default:
                shown = 0;
                break;
        }
        int diff = Math.abs(degrees - (360 - shown) % 360);
        if (Math.min(diff, 360 - diff) <= MATCH_TOLERANCE_DEG) {
            rotationUnlocked = true;
            orientationListener.disable();
            setRequestedOrientation(ActivityInfo.SCREEN_ORIENTATION_FULL_SENSOR);
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
