package io.github.jesserockz.littlevideos;

import android.app.AlertDialog;
import android.content.ActivityNotFoundException;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.text.InputFilter;
import android.text.InputType;
import android.view.LayoutInflater;
import android.view.View;
import android.view.WindowManager;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.Switch;
import android.widget.TextView;
import android.widget.Toast;

import java.util.List;

/** Parent-facing settings. Plain framework widgets only. */
public class SettingsActivity extends AppActivity {
    private static final int REQ_PICK_FOLDER = 1001;

    private interface IntCallback {
        void run(int value);
    }

    private static final class Row {
        View root;
        TextView title;
        TextView summary;
        Switch toggle;
    }

    private Prefs prefs;
    private final Handler handler = new Handler(Looper.getMainLooper());
    private LinearLayout list;

    private Row rowFolder;
    private Row rowSubfolders;
    private Row rowTitles;
    private Row rowOnEnd;
    private Row rowSort;
    private Row rowGrid;
    private Row rowCount;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        prefs = new Prefs(this);
        setContentView(R.layout.activity_settings);
        Ui.applyInsets(findViewById(R.id.settings_root));
        list = (LinearLayout) findViewById(R.id.settings_list);
        findViewById(R.id.settings_back).setOnClickListener(v -> finish());
        buildRows();
    }

    private Row addRow(int titleRes, View.OnClickListener onClick) {
        Row r = new Row();
        r.root = LayoutInflater.from(this).inflate(R.layout.row_setting, list, false);
        r.title = (TextView) r.root.findViewById(R.id.row_title);
        r.summary = (TextView) r.root.findViewById(R.id.row_summary);
        r.toggle = (Switch) r.root.findViewById(R.id.row_switch);
        r.title.setText(titleRes);
        if (onClick != null) {
            r.root.setOnClickListener(onClick);
        } else {
            r.root.setClickable(false);
            r.root.setBackground(null);
        }
        list.addView(r.root);
        return r;
    }

    private void buildRows() {
        // 1. Video folder
        rowFolder = addRow(R.string.settings_folder_title, v -> pickFolder());

        // 2. Include subfolders
        rowSubfolders = addRow(R.string.settings_subfolders_title, null);
        setupSwitch(rowSubfolders, prefs.getIncludeSubfolders(),
                R.string.settings_subfolders_on, R.string.settings_subfolders_off, on -> {
                    prefs.setIncludeSubfolders(on);
                    prefs.setLibraryDirty(true);
                });

        // 3. Show titles
        rowTitles = addRow(R.string.settings_titles_title, null);
        setupSwitch(rowTitles, prefs.getShowTitles(),
                R.string.settings_titles_on, R.string.settings_titles_off, on -> {
                    prefs.setShowTitles(on);
                    prefs.setLibraryDirty(true);
                });

        // 4. When a video ends
        rowOnEnd = addRow(R.string.settings_onend_title, v ->
                chooseOne(R.string.settings_onend_title, R.array.onend_options, prefs.getOnEnd(), which -> {
                    prefs.setOnEnd(which);
                    updateSummaries();
                }));

        // 5. Sort
        rowSort = addRow(R.string.settings_sort_title, v ->
                chooseOne(R.string.settings_sort_title, R.array.sort_options, prefs.getSort(), which -> {
                    prefs.setSort(which);
                    prefs.setLibraryDirty(true);
                    updateSummaries();
                }));

        // 6. Grid size
        rowGrid = addRow(R.string.settings_grid_title, v ->
                chooseOne(R.string.settings_grid_title, R.array.grid_options, prefs.getGridSize(), which -> {
                    prefs.setGridSize(which);
                    prefs.setLibraryDirty(true);
                    updateSummaries();
                }));

        // 7. Change PIN
        Row rowPin = addRow(R.string.settings_pin_title, v -> showPinEntry(null));
        rowPin.summary.setText(R.string.settings_pin_summary);

        // 8. Rebuild thumbnails
        Row rowRebuild = addRow(R.string.settings_rebuild_title, v -> rebuildThumbnails());
        rowRebuild.summary.setText(R.string.settings_rebuild_summary);

        // 9. Info: videos found
        rowCount = addRow(R.string.settings_count_title, null);

        // 10. Lock the app in place
        Row rowLock = addRow(R.string.settings_lock_title, null);
        setupSwitch(rowLock, prefs.getLockApp(),
                R.string.settings_lock_on, R.string.settings_lock_off, on -> {
                    prefs.setLockApp(on);
                    if (on) {
                        Ui.allowPinAgain();
                        Ui.pin(this);
                    } else {
                        Ui.unpin(this);
                    }
                });

        // 11. Exit, the only way out of the app short of the system unpin gesture
        Row rowExit = addRow(R.string.settings_exit_title, v -> {
            Ui.exitRequested = true;
            Ui.unpin(this);
            finishAndRemoveTask();
        });
        rowExit.summary.setText(R.string.settings_exit_summary);

        // 12. How pinning works
        Row rowPinning = addRow(R.string.settings_pinning_title, v -> showMessage(
                R.string.pinning_dialog_title, getString(R.string.pinning_dialog_message)));
        rowPinning.summary.setText(R.string.settings_pinning_summary);

        // 13. About
        Row rowAbout = addRow(R.string.settings_about_title, v -> showMessage(
                R.string.about_dialog_title, getString(R.string.about_dialog_message, versionName())));
        rowAbout.summary.setText(R.string.settings_about_summary);

        updateSummaries();
    }

    private interface BoolCallback {
        void run(boolean value);
    }

    private void setupSwitch(final Row r, boolean initial, final int onSummary, final int offSummary,
                             final BoolCallback cb) {
        r.toggle.setVisibility(View.VISIBLE);
        r.toggle.setChecked(initial);
        r.summary.setText(initial ? onSummary : offSummary);
        r.toggle.setOnCheckedChangeListener((b, checked) -> {
            r.summary.setText(checked ? onSummary : offSummary);
            cb.run(checked);
        });
        // The switch itself is not clickable; the whole row is.
        r.root.setOnClickListener(v -> r.toggle.toggle());
    }

    private void updateSummaries() {
        rowOnEnd.summary.setText(getResources().getStringArray(R.array.onend_options)[clamp(prefs.getOnEnd(), 2)]);
        rowSort.summary.setText(getResources().getStringArray(R.array.sort_options)[clamp(prefs.getSort(), 2)]);
        rowGrid.summary.setText(getResources().getStringArray(R.array.grid_options)[clamp(prefs.getGridSize(), 2)]);
    }

    private static int clamp(int v, int max) {
        return Math.max(0, Math.min(max, v));
    }

    @Override
    protected void onResume() {
        super.onResume();
        refreshFolderAndCount();
    }

    private void refreshFolderAndCount() {
        List<VideoItem> current = VideoLibrary.current();
        if (current.isEmpty() && prefs.isLibraryDirty()) {
            rowCount.summary.setText(R.string.settings_count_none);
        } else {
            rowCount.summary.setText(getString(R.string.settings_count_value, current.size()));
        }
        final String tree = prefs.getTreeUri();
        if (tree == null) {
            rowFolder.summary.setText(R.string.settings_folder_not_set);
            return;
        }
        rowFolder.summary.setText(R.string.settings_folder_not_set);
        // Provider query, so off the main thread.
        new Thread(() -> {
            final String name = VideoLibrary.folderName(getApplicationContext(), Uri.parse(tree));
            handler.post(() -> {
                if (!isDestroyed() && tree.equals(prefs.getTreeUri())) {
                    rowFolder.summary.setText(name);
                }
            });
        }, "folder-name").start();
    }

    private void pickFolder() {
        Intent i = new Intent(Intent.ACTION_OPEN_DOCUMENT_TREE);
        i.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION
                | Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
                | Intent.FLAG_GRANT_PREFIX_URI_PERMISSION);
        try {
            startActivityForResult(i, REQ_PICK_FOLDER);
        } catch (ActivityNotFoundException e) {
            Toast.makeText(this, R.string.settings_folder_no_picker, Toast.LENGTH_LONG).show();
        }
    }

    @Override
    @SuppressWarnings("deprecation")
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode != REQ_PICK_FOLDER || resultCode != RESULT_OK || data == null || data.getData() == null) {
            return;
        }
        Uri picked = data.getData();
        try {
            getContentResolver().takePersistableUriPermission(picked, Intent.FLAG_GRANT_READ_URI_PERMISSION);
        } catch (RuntimeException e) {
            Toast.makeText(this, R.string.settings_folder_error, Toast.LENGTH_LONG).show();
            return;
        }
        String previous = prefs.getTreeUri();
        if (previous != null && !previous.equals(picked.toString())) {
            try {
                getContentResolver().releasePersistableUriPermission(
                        Uri.parse(previous), Intent.FLAG_GRANT_READ_URI_PERMISSION);
            } catch (RuntimeException ignored) {
                // The old grant may already be gone; nothing to release.
            }
        }
        prefs.setTreeUri(picked.toString());
        prefs.setLibraryDirty(true);
        VideoLibrary.setCurrent(null);
        clearCachesAsync(null);
        refreshFolderAndCount();
    }

    private void rebuildThumbnails() {
        prefs.setLibraryDirty(true);
        clearCachesAsync(() -> Toast.makeText(this, R.string.settings_rebuild_done, Toast.LENGTH_SHORT).show());
    }

    private void clearCachesAsync(final Runnable onDone) {
        final Handler h = handler;
        new Thread(() -> {
            ThumbnailLoader.get(getApplicationContext()).clearCaches();
            if (onDone != null) {
                h.post(() -> {
                    if (!isDestroyed()) {
                        onDone.run();
                    }
                });
            }
        }, "clear-caches").start();
    }

    private void chooseOne(int titleRes, int arrayRes, int current, final IntCallback cb) {
        new AlertDialog.Builder(this)
                .setTitle(titleRes)
                .setSingleChoiceItems(getResources().getStringArray(arrayRes), clamp(current, 2), (d, which) -> {
                    cb.run(which);
                    d.dismiss();
                })
                .setNegativeButton(R.string.settings_cancel, null)
                .show();
    }

    /** Two-step PIN change. firstEntry is null for the "new PIN" step, or the value to confirm. */
    private void showPinEntry(final String firstEntry) {
        final EditText input = new EditText(this);
        input.setInputType(InputType.TYPE_CLASS_NUMBER | InputType.TYPE_NUMBER_VARIATION_PASSWORD);
        input.setFilters(new InputFilter[]{new InputFilter.LengthFilter(4)});
        input.setSingleLine(true);
        FrameLayout box = new FrameLayout(this);
        int pad = Ui.dp(this, 24);
        box.setPadding(pad, Ui.dp(this, 8), pad, 0);
        box.addView(input);

        final AlertDialog dialog = new AlertDialog.Builder(this)
                .setTitle(firstEntry == null ? R.string.pin_new_title : R.string.pin_confirm_title)
                .setView(box)
                .setPositiveButton(R.string.settings_ok, null)
                .setNegativeButton(R.string.settings_cancel, null)
                .create();
        dialog.getWindow().setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_STATE_VISIBLE);
        dialog.show();
        // Overridden after show() so a bad entry keeps the dialog open.
        dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener(v -> {
            String s = input.getText().toString();
            if (!s.matches("[0-9]{4}")) {
                input.setError(getString(R.string.pin_error_length));
                return;
            }
            dialog.dismiss();
            if (firstEntry == null) {
                showPinEntry(s);
            } else if (firstEntry.equals(s)) {
                prefs.setPin(s);
                Toast.makeText(this, R.string.pin_saved, Toast.LENGTH_SHORT).show();
            } else {
                Toast.makeText(this, R.string.pin_mismatch, Toast.LENGTH_LONG).show();
            }
        });
    }

    private void showMessage(int titleRes, String message) {
        new AlertDialog.Builder(this)
                .setTitle(titleRes)
                .setMessage(message)
                .setPositiveButton(R.string.settings_close, null)
                .show();
    }

    private String versionName() {
        try {
            String v = getPackageManager().getPackageInfo(getPackageName(), 0).versionName;
            return v == null ? "1.0" : v;
        } catch (PackageManager.NameNotFoundException e) {
            return "1.0";
        }
    }

    @Override
    protected void onDestroy() {
        handler.removeCallbacksAndMessages(null);
        super.onDestroy();
    }
}
