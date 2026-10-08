package io.github.jesserockz.littlevideos;

import android.app.Activity;
import android.content.Intent;
import android.content.res.Configuration;
import android.net.Uri;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.view.LayoutInflater;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewGroup;
import android.widget.BaseAdapter;
import android.widget.Button;
import android.widget.GridView;
import android.widget.ImageButton;
import android.widget.ImageView;
import android.widget.TextView;

import java.util.ArrayList;
import java.util.List;

/** Child-facing home: a grid of videos and nothing else. Launcher activity. */
public class GridActivity extends AppActivity {
    /** How long the gear must be held before the parent gate opens. */
    private static final long GEAR_HOLD_MS = 2000;
    private static final float GEAR_DIM_ALPHA = 0.35f;

    private enum State { LIST, NO_FOLDER, EMPTY, UNAVAILABLE }

    private Prefs prefs;
    private ThumbnailLoader thumbs;
    private final Handler handler = new Handler(Looper.getMainLooper());

    private GridView grid;
    private View emptyPanel;
    private TextView emptyTitle;
    private TextView emptyMessage;
    private Button emptyButton;
    private View progress;
    private ImageButton gear;

    private final List<VideoItem> items = new ArrayList<>();
    private VideoAdapter adapter;
    private State state = State.LIST;
    private String folderName = "";
    private int scanGeneration = 0;
    private boolean scanning = false;
    private int savedFirstVisible = 0;

    // Gear press tracking
    private float gearDownX;
    private float gearDownY;
    private boolean gearArmed = false;
    private final Runnable openGate = new Runnable() {
        @Override
        public void run() {
            gearArmed = false;
            resetGear();
            startActivity(new Intent(GridActivity.this, PinActivity.class));
        }
    };

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        // A fresh launch, so an earlier Exit or unpin no longer applies.
        Ui.resetPinState();
        prefs = new Prefs(this);
        thumbs = ThumbnailLoader.get(this);
        setContentView(R.layout.activity_grid);
        Ui.applyInsets(findViewById(R.id.grid_root));

        grid = (GridView) findViewById(R.id.grid);
        emptyPanel = findViewById(R.id.empty_panel);
        emptyTitle = (TextView) findViewById(R.id.empty_title);
        emptyMessage = (TextView) findViewById(R.id.empty_message);
        emptyButton = (Button) findViewById(R.id.empty_button);
        progress = findViewById(R.id.scan_progress);
        gear = (ImageButton) findViewById(R.id.gear);

        adapter = new VideoAdapter();
        grid.setAdapter(adapter);
        // Deliberately no OnItemLongClickListener: cards have no long-press behaviour at all.
        grid.setOnItemClickListener((parent, view, position, id) -> {
            if (position < 0 || position >= items.size()) {
                return;
            }
            VideoLibrary.setCurrent(new ArrayList<>(items));
            Intent i = new Intent(this, PlayerActivity.class);
            i.putExtra(PlayerActivity.EXTRA_INDEX, position);
            startActivity(i);
        });

        emptyButton.setOnClickListener(v -> startActivity(new Intent(this, PinActivity.class)));
        setupGear();
        if (savedInstanceState != null) {
            savedFirstVisible = savedInstanceState.getInt("firstVisible", 0);
        }
        applyGridPrefs();
    }

    /**
     * The gear is a parent gate and needs a continuous 2 s press. It is NOT built on
     * setOnLongClickListener because the platform long press fires at about 500 ms, which a
     * determined toddler can easily hold. A Handler timer we control is the only way to get 2 s.
     */
    private void setupGear() {
        final float slop = Ui.dp(this, 24);
        gear.setOnTouchListener((v, event) -> {
            switch (event.getActionMasked()) {
                case MotionEvent.ACTION_DOWN:
                    gearDownX = event.getRawX();
                    gearDownY = event.getRawY();
                    gearArmed = true;
                    gear.animate().cancel();
                    gear.setAlpha(GEAR_DIM_ALPHA);
                    // Visible progress so an adult can see the hold is registering.
                    gear.animate().alpha(1f).setDuration(GEAR_HOLD_MS)
                            .setInterpolator(new android.view.animation.LinearInterpolator()).start();
                    handler.removeCallbacks(openGate);
                    handler.postDelayed(openGate, GEAR_HOLD_MS);
                    return true;
                case MotionEvent.ACTION_MOVE:
                    if (gearArmed) {
                        float dx = event.getRawX() - gearDownX;
                        float dy = event.getRawY() - gearDownY;
                        if (dx * dx + dy * dy > slop * slop) {
                            cancelGear();
                        }
                    }
                    return true;
                case MotionEvent.ACTION_UP:
                case MotionEvent.ACTION_CANCEL:
                    cancelGear();
                    return true;
                default:
                    return true;
            }
        });
    }

    private void cancelGear() {
        gearArmed = false;
        handler.removeCallbacks(openGate);
        resetGear();
    }

    private void resetGear() {
        gear.animate().cancel();
        gear.setAlpha(GEAR_DIM_ALPHA);
    }

    private boolean isLandscape() {
        return getResources().getConfiguration().orientation == Configuration.ORIENTATION_LANDSCAPE;
    }

    private void applyGridPrefs() {
        grid.setNumColumns(prefs.columns(isLandscape()));
        adapter.notifyDataSetChanged();
    }

    @Override
    public void onConfigurationChanged(Configuration newConfig) {
        super.onConfigurationChanged(newConfig);
        applyGridPrefs();
        Ui.applyImmersive(this);
    }

    @Override
    protected void onResume() {
        super.onResume();
        if (Ui.exitRequested) {
            // Exit unpinned, and closing the task can lose out to the unpin's lock screen.
            Ui.exitRequested = false;
            finishAndRemoveTask();
            return;
        }
        Ui.applyImmersive(this);
        if (prefs.getLockApp()) {
            Ui.pinUnlessUnpinned(this);
        }
        applyGridPrefs();
        resetGear();

        String tree = prefs.getTreeUri();
        if (tree == null) {
            scanGeneration++;
            items.clear();
            showState(State.NO_FOLDER);
            return;
        }
        Uri treeUri = Uri.parse(tree);
        if (!VideoLibrary.hasPermission(this, treeUri)) {
            scanGeneration++;
            items.clear();
            VideoLibrary.setCurrent(null);
            showState(State.UNAVAILABLE);
            return;
        }
        if (scanning) {
            return;
        }
        List<VideoItem> known = VideoLibrary.current();
        if (prefs.isLibraryDirty() || known.isEmpty()) {
            startScan(treeUri);
        } else {
            // Returning from the player: the list is still valid, keep it and the scroll position.
            if (items.isEmpty()) {
                items.addAll(known);
                adapter.notifyDataSetChanged();
                grid.post(() -> grid.setSelection(savedFirstVisible));
            }
            showState(State.LIST);
        }
    }

    private void startScan(final Uri treeUri) {
        scanning = true;
        final int gen = ++scanGeneration;
        // Cleared up front so a settings change made mid-scan re-marks it dirty.
        prefs.setLibraryDirty(false);
        progress.setVisibility(View.VISIBLE);
        final boolean recurse = prefs.getIncludeSubfolders();
        final int sort = prefs.getSort();
        final Activity self = this;
        new Thread(() -> {
            List<VideoItem> result = null;
            String name = "";
            boolean denied = false;
            try {
                result = VideoLibrary.scan(self, treeUri, recurse, sort);
                thumbs.applyStoredDurations(result);
                name = VideoLibrary.folderName(self, treeUri);
            } catch (VideoLibrary.AccessException e) {
                denied = true;
            } catch (Throwable t) {
                result = new ArrayList<>();
            }
            final List<VideoItem> fin = result;
            final String finName = name;
            final boolean finDenied = denied;
            handler.post(() -> {
                if (gen != scanGeneration || isDestroyed()) {
                    return;
                }
                scanning = false;
                progress.setVisibility(View.GONE);
                items.clear();
                if (finDenied) {
                    VideoLibrary.setCurrent(null);
                    showState(State.UNAVAILABLE);
                    return;
                }
                items.addAll(fin);
                VideoLibrary.setCurrent(new ArrayList<>(fin));
                folderName = finName;
                adapter.notifyDataSetChanged();
                if (items.isEmpty()) {
                    showState(State.EMPTY);
                } else {
                    showState(State.LIST);
                    grid.post(() -> grid.setSelection(Math.min(savedFirstVisible, items.size() - 1)));
                }
            });
        }, "library-scan").start();
    }

    private void showState(State s) {
        state = s;
        if (s != State.UNAVAILABLE && s != State.NO_FOLDER && s != State.EMPTY) {
            emptyPanel.setVisibility(View.GONE);
            grid.setVisibility(View.VISIBLE);
            return;
        }
        grid.setVisibility(View.GONE);
        emptyPanel.setVisibility(View.VISIBLE);
        progress.setVisibility(View.GONE);
        scanning = false;
        if (s == State.NO_FOLDER) {
            emptyTitle.setText(R.string.grid_setup_title);
            emptyMessage.setText(R.string.grid_setup_message);
            emptyButton.setVisibility(View.VISIBLE);
        } else if (s == State.UNAVAILABLE) {
            emptyTitle.setText(R.string.grid_unavailable_title);
            emptyMessage.setText(R.string.grid_unavailable_message);
            emptyButton.setVisibility(View.VISIBLE);
        } else {
            emptyTitle.setText(R.string.grid_empty_title);
            emptyMessage.setText(getString(R.string.grid_empty_message, folderName));
            emptyButton.setVisibility(View.GONE);
        }
    }

    @Override
    protected void onPause() {
        savedFirstVisible = grid.getFirstVisiblePosition();
        cancelGear();
        super.onPause();
    }

    @Override
    protected void onSaveInstanceState(Bundle outState) {
        super.onSaveInstanceState(outState);
        outState.putInt("firstVisible", grid.getFirstVisiblePosition());
    }

    @Override
    protected void onDestroy() {
        handler.removeCallbacksAndMessages(null);
        scanGeneration++;
        super.onDestroy();
    }

    /** The grid is the bottom of the task, so back would leave the app. It does nothing instead. */
    @Override
    @SuppressWarnings("deprecation")
    public void onBackPressed() {
        // Deliberately empty.
    }

    @Override
    public void onWindowFocusChanged(boolean hasFocus) {
        super.onWindowFocusChanged(hasFocus);
        if (hasFocus) {
            // Focus comes back once the "Pin app?" prompt closes, so this records an accepted pin.
            Ui.isPinned(this);
            Ui.applyImmersive(this);
        }
    }

    private final class VideoAdapter extends BaseAdapter {
        @Override
        public int getCount() {
            return items.size();
        }

        @Override
        public Object getItem(int position) {
            return items.get(position);
        }

        @Override
        public long getItemId(int position) {
            return position;
        }

        @Override
        public View getView(int position, View convertView, ViewGroup parent) {
            final Holder h;
            View row = convertView;
            if (row == null) {
                row = LayoutInflater.from(GridActivity.this).inflate(R.layout.item_video, parent, false);
                h = new Holder();
                h.card = row.findViewById(R.id.card);
                h.thumb = (ImageView) row.findViewById(R.id.thumb);
                h.duration = (TextView) row.findViewById(R.id.duration);
                h.title = (TextView) row.findViewById(R.id.title);
                h.card.setClipToOutline(true);
                row.setTag(h);
            } else {
                h = (Holder) row.getTag();
            }
            final VideoItem item = items.get(position);

            int colW = ((GridView) parent).getColumnWidth();
            if (colW <= 0) {
                int cols = Math.max(1, prefs.columns(isLandscape()));
                colW = (getResources().getDisplayMetrics().widthPixels - Ui.dp(GridActivity.this, 32)) / cols;
            }
            int cardH = colW * 9 / 16;
            ViewGroup.LayoutParams lp = h.card.getLayoutParams();
            if (lp.height != cardH) {
                lp.height = cardH;
                h.card.setLayoutParams(lp);
            }

            if (prefs.getShowTitles()) {
                h.title.setVisibility(View.VISIBLE);
                h.title.setText(item.title);
            } else {
                h.title.setVisibility(View.GONE);
            }

            h.thumb.setImageResource(R.drawable.ic_film_placeholder);
            thumbs.load(item, h.thumb, colW, cardH, () -> bindDuration(h, item));
            bindDuration(h, item);
            return row;
        }

        private void bindDuration(Holder h, VideoItem item) {
            if (item.durationMs > 0) {
                h.duration.setText(Ui.formatDuration(item.durationMs));
                h.duration.setVisibility(View.VISIBLE);
            } else {
                h.duration.setVisibility(View.GONE);
            }
        }
    }

    private static final class Holder {
        View card;
        ImageView thumb;
        TextView duration;
        TextView title;
    }
}
