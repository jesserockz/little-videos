package io.github.jesserockz.littlevideos;

import android.app.Activity;
import android.content.Intent;
import android.content.res.Configuration;
import android.os.Bundle;
import android.os.CountDownTimer;
import android.os.SystemClock;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.view.animation.CycleInterpolator;
import android.view.animation.TranslateAnimation;
import android.widget.LinearLayout;
import android.widget.TextView;

import java.util.ArrayList;
import java.util.List;

/** Parent gate: a 4-digit keypad in front of the settings. */
public class PinActivity extends Activity {
    private static final int PIN_LENGTH = 4;
    private static final int MAX_FAILURES = 5;
    private static final long LOCKOUT_MS = 30000;

    // In memory only: cleared when the process dies.
    private static int failures = 0;
    private static long lockedUntil = 0;

    private Prefs prefs;
    private final StringBuilder entry = new StringBuilder();
    private final List<View> dots = new ArrayList<>();
    private final List<View> keys = new ArrayList<>();
    private LinearLayout dotsRow;
    private LinearLayout keypad;
    private TextView message;
    private CountDownTimer timer;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        prefs = new Prefs(this);
        setContentView(R.layout.activity_pin);
        Ui.applyInsets(findViewById(R.id.pin_root));
        dotsRow = (LinearLayout) findViewById(R.id.dots);
        keypad = (LinearLayout) findViewById(R.id.keypad);
        message = (TextView) findViewById(R.id.pin_message);
        buildDots();
        buildKeypad();
    }

    private void buildDots() {
        int size = getResources().getDimensionPixelSize(R.dimen.dot_size);
        int gap = Ui.dp(this, 10);
        dotsRow.removeAllViews();
        dots.clear();
        for (int i = 0; i < PIN_LENGTH; i++) {
            View d = new View(this);
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(size, size);
            lp.setMargins(gap, 0, gap, 0);
            d.setLayoutParams(lp);
            d.setBackgroundResource(R.drawable.dot_empty);
            dotsRow.addView(d);
            dots.add(d);
        }
    }

    /** 3x4 grid of round keys: 1-9, then cancel, 0, delete. Sized so it fits landscape phones too. */
    private void buildKeypad() {
        int maxKey = getResources().getDimensionPixelSize(R.dimen.key_size);
        int heightPx = getResources().getDisplayMetrics().heightPixels;
        int gap = Ui.dp(this, 10);
        // Leave room for the title, dots and message above the four rows.
        int fit = (heightPx - Ui.dp(this, 190)) / 4 - gap * 2;
        int size = Math.max(Ui.dp(this, 44), Math.min(maxKey, fit));

        keypad.removeAllViews();
        keys.clear();
        String[][] layout = {
                {"1", "2", "3"},
                {"4", "5", "6"},
                {"7", "8", "9"},
                {"C", "0", "D"},
        };
        for (String[] rowKeys : layout) {
            LinearLayout row = new LinearLayout(this);
            row.setOrientation(LinearLayout.HORIZONTAL);
            for (final String k : rowKeys) {
                TextView key = new TextView(this);
                LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(size, size);
                lp.setMargins(gap, gap, gap, gap);
                key.setLayoutParams(lp);
                key.setGravity(Gravity.CENTER);
                key.setBackgroundResource(R.drawable.bg_key);
                key.setTextColor(getResources().getColor(R.color.textPrimary, getTheme()));
                key.setClickable(true);
                key.setHapticFeedbackEnabled(false);
                if (k.equals("C")) {
                    key.setText(R.string.pin_cancel);
                    key.setTextSize(TypedValue.COMPLEX_UNIT_SP, 15);
                    key.setOnClickListener(v -> finish());
                } else if (k.equals("D")) {
                    key.setText(R.string.pin_delete);
                    key.setTextSize(TypedValue.COMPLEX_UNIT_SP, 15);
                    key.setOnClickListener(v -> onDelete());
                } else {
                    key.setText(k);
                    key.setTextSize(TypedValue.COMPLEX_UNIT_SP, 28);
                    key.setOnClickListener(v -> onDigit(k));
                }
                row.addView(key);
                keys.add(key);
            }
            keypad.addView(row);
        }
        setKeysEnabled(!isLocked());
    }

    private boolean isLocked() {
        return SystemClock.elapsedRealtime() < lockedUntil;
    }

    private void setKeysEnabled(boolean enabled) {
        for (View v : keys) {
            v.setEnabled(enabled);
            v.setAlpha(enabled ? 1f : 0.35f);
        }
    }

    private void onDigit(String d) {
        if (isLocked() || entry.length() >= PIN_LENGTH) {
            return;
        }
        message.setText("");
        entry.append(d);
        updateDots();
        if (entry.length() == PIN_LENGTH) {
            checkPin();
        }
    }

    private void onDelete() {
        if (isLocked() || entry.length() == 0) {
            return;
        }
        entry.setLength(entry.length() - 1);
        updateDots();
    }

    private void updateDots() {
        for (int i = 0; i < dots.size(); i++) {
            dots.get(i).setBackgroundResource(i < entry.length() ? R.drawable.dot_filled : R.drawable.dot_empty);
        }
    }

    private void checkPin() {
        if (entry.toString().equals(prefs.getPin())) {
            failures = 0;
            startActivity(new Intent(this, SettingsActivity.class));
            finish();
            return;
        }
        entry.setLength(0);
        updateDots();
        failures++;
        shake();
        if (failures >= MAX_FAILURES) {
            failures = 0;
            lockedUntil = SystemClock.elapsedRealtime() + LOCKOUT_MS;
            startLockCountdown();
        } else {
            message.setText(R.string.pin_wrong);
        }
    }

    private void shake() {
        TranslateAnimation a = new TranslateAnimation(0, Ui.dp(this, 14), 0, 0);
        a.setDuration(400);
        a.setInterpolator(new CycleInterpolator(3));
        dotsRow.startAnimation(a);
    }

    private void startLockCountdown() {
        if (timer != null) {
            timer.cancel();
        }
        long remaining = lockedUntil - SystemClock.elapsedRealtime();
        if (remaining <= 0) {
            setKeysEnabled(true);
            return;
        }
        setKeysEnabled(false);
        message.setText(getString(R.string.pin_locked, (remaining + 999) / 1000));
        timer = new CountDownTimer(remaining, 1000) {
            @Override
            public void onTick(long millisUntilFinished) {
                message.setText(getString(R.string.pin_locked, (millisUntilFinished + 999) / 1000));
            }

            @Override
            public void onFinish() {
                message.setText("");
                setKeysEnabled(true);
            }
        };
        timer.start();
    }

    @Override
    protected void onResume() {
        super.onResume();
        Ui.applyImmersive(this);
        if (isLocked()) {
            startLockCountdown();
        }
    }

    @Override
    protected void onPause() {
        if (timer != null) {
            timer.cancel();
            timer = null;
        }
        super.onPause();
    }

    @Override
    protected void onDestroy() {
        if (timer != null) {
            timer.cancel();
        }
        super.onDestroy();
    }

    @Override
    public void onConfigurationChanged(Configuration newConfig) {
        super.onConfigurationChanged(newConfig);
        buildKeypad();
        Ui.applyImmersive(this);
    }

    @Override
    public void onWindowFocusChanged(boolean hasFocus) {
        super.onWindowFocusChanged(hasFocus);
        if (hasFocus) {
            Ui.applyImmersive(this);
        }
    }
}
