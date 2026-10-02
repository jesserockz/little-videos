package io.github.jesserockz.littlevideos;

import android.app.Activity;
import android.app.ActivityManager;
import android.content.Context;
import android.graphics.Insets;
import android.os.Build;
import android.view.View;
import android.view.Window;
import android.view.WindowInsets;
import android.view.WindowInsetsController;

import java.util.Locale;

/** Small shared helpers for the activities. */
final class Ui {
    private Ui() {
    }

    static int dp(Context c, float v) {
        return Math.round(v * c.getResources().getDisplayMetrics().density);
    }

    /** Hides both system bars; a swipe from the edge shows them transiently. */
    @SuppressWarnings("deprecation")
    static void applyImmersive(Activity a) {
        Window w = a.getWindow();
        if (Build.VERSION.SDK_INT >= 30) {
            WindowInsetsController c = w.getInsetsController();
            if (c != null) {
                c.hide(WindowInsets.Type.statusBars() | WindowInsets.Type.navigationBars());
                c.setSystemBarsBehavior(WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE);
            }
        } else {
            w.getDecorView().setSystemUiVisibility(
                    View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
                            | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                            | View.SYSTEM_UI_FLAG_FULLSCREEN
                            | View.SYSTEM_UI_FLAG_LAYOUT_STABLE
                            | View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
                            | View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN);
        }
    }

    /** True while the task is pinned, whether the app or the parent pinned it. */
    static boolean isPinned(Activity a) {
        ActivityManager am = (ActivityManager) a.getSystemService(Context.ACTIVITY_SERVICE);
        return am != null && am.getLockTaskModeState() != ActivityManager.LOCK_TASK_MODE_NONE;
    }

    /**
     * Asks Android to pin this task. Needs no permission: the system shows its own "Pin app?"
     * confirmation, and once pinned, home, recents and the notification shade are all disabled
     * until the device's unpin gesture (and device PIN, if that option is on) is used.
     */
    static void pin(Activity a) {
        if (isPinned(a)) {
            return;
        }
        try {
            a.startLockTask();
        } catch (RuntimeException ignored) {
            // Not resumed, or the system refused. The next resume tries again.
        }
    }

    /** Leaves pinning. Allowed because the app (or the user, on this app's task) started it. */
    static void unpin(Activity a) {
        if (!isPinned(a)) {
            return;
        }
        try {
            a.stopLockTask();
        } catch (RuntimeException ignored) {
            // Pinned by something we may not stop, such as a device policy.
        }
    }

    /**
     * Pads the view by the system bar and display cutout insets, on top of its existing padding.
     * Needed because targetSdk 35 forces edge-to-edge layout on Android 15.
     */
    @SuppressWarnings("deprecation")
    static void applyInsets(View v) {
        final int bl = v.getPaddingLeft();
        final int bt = v.getPaddingTop();
        final int br = v.getPaddingRight();
        final int bb = v.getPaddingBottom();
        v.setOnApplyWindowInsetsListener((view, insets) -> {
            int l;
            int t;
            int r;
            int b;
            if (Build.VERSION.SDK_INT >= 30) {
                Insets i = insets.getInsets(WindowInsets.Type.systemBars() | WindowInsets.Type.displayCutout());
                l = i.left;
                t = i.top;
                r = i.right;
                b = i.bottom;
            } else {
                l = insets.getSystemWindowInsetLeft();
                t = insets.getSystemWindowInsetTop();
                r = insets.getSystemWindowInsetRight();
                b = insets.getSystemWindowInsetBottom();
            }
            view.setPadding(bl + l, bt + t, br + r, bb + b);
            return insets;
        });
        v.requestApplyInsets();
    }

    /** m:ss, or h:mm:ss for videos of an hour or more. */
    static String formatDuration(long ms) {
        long totalSec = Math.max(0, ms / 1000);
        long h = totalSec / 3600;
        long m = (totalSec % 3600) / 60;
        long s = totalSec % 60;
        if (h > 0) {
            return String.format(Locale.ROOT, "%d:%02d:%02d", h, m, s);
        }
        return String.format(Locale.ROOT, "%d:%02d", m, s);
    }
}
