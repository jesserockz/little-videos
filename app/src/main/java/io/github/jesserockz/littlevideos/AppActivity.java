package io.github.jesserockz.littlevideos;

import android.app.Activity;
import android.content.Intent;
import android.os.Bundle;

/**
 * Base for every screen. Tells pinning when the user leaves the app with home or recents, so
 * the app asks to pin again on their next visit after an unpin.
 *
 * onUserLeaveHint() alone cannot say that: Android also calls it when the app opens one of its
 * own screens. So a launch from here is remembered and its hint ignored.
 */
abstract class AppActivity extends Activity {
    private static boolean launchingOwnScreen = false;

    @Override
    public void startActivityForResult(Intent intent, int requestCode, Bundle options) {
        // startActivity() lands here too.
        launchingOwnScreen = true;
        super.startActivityForResult(intent, requestCode, options);
    }

    @Override
    protected void onResume() {
        super.onResume();
        // A launch whose hint never came (it carried FLAG_ACTIVITY_NO_USER_ACTION, or failed)
        // must not swallow the next real one.
        launchingOwnScreen = false;
    }

    @Override
    protected void onUserLeaveHint() {
        super.onUserLeaveHint();
        if (launchingOwnScreen) {
            launchingOwnScreen = false;
        } else {
            Ui.allowPinAgain();
        }
    }
}
