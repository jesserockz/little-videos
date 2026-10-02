package io.github.jesserockz.littlevideos;

import android.content.Context;
import android.content.SharedPreferences;

/** Thin typed wrapper over the app's single SharedPreferences file. */
public final class Prefs {
    public static final int END_GRID = 0;
    public static final int END_NEXT = 1;
    public static final int END_REPEAT = 2;

    public static final int SORT_NAME = 0;
    public static final int SORT_NEWEST = 1;
    public static final int SORT_OLDEST = 2;

    public static final int GRID_LARGE = 0;
    public static final int GRID_MEDIUM = 1;
    public static final int GRID_SMALL = 2;

    private static final String K_TREE_URI = "treeUri";
    private static final String K_PIN = "pin";
    private static final String K_SUBFOLDERS = "includeSubfolders";
    private static final String K_TITLES = "showTitles";
    private static final String K_ON_END = "onEnd";
    private static final String K_SORT = "sort";
    private static final String K_GRID = "gridSize";
    private static final String K_DIRTY = "libraryDirty";
    private static final String K_LOCK = "lockApp";

    private final SharedPreferences sp;

    public Prefs(Context ctx) {
        sp = ctx.getApplicationContext().getSharedPreferences("little_videos", Context.MODE_PRIVATE);
    }

    public String getTreeUri() {
        return sp.getString(K_TREE_URI, null);
    }

    public void setTreeUri(String uri) {
        if (uri == null) {
            sp.edit().remove(K_TREE_URI).apply();
        } else {
            sp.edit().putString(K_TREE_URI, uri).apply();
        }
    }

    public String getPin() {
        return sp.getString(K_PIN, "1234");
    }

    public void setPin(String pin) {
        sp.edit().putString(K_PIN, pin).apply();
    }

    public boolean getIncludeSubfolders() {
        return sp.getBoolean(K_SUBFOLDERS, true);
    }

    public void setIncludeSubfolders(boolean v) {
        sp.edit().putBoolean(K_SUBFOLDERS, v).apply();
    }

    public boolean getShowTitles() {
        return sp.getBoolean(K_TITLES, true);
    }

    public void setShowTitles(boolean v) {
        sp.edit().putBoolean(K_TITLES, v).apply();
    }

    public int getOnEnd() {
        return sp.getInt(K_ON_END, END_GRID);
    }

    public void setOnEnd(int v) {
        sp.edit().putInt(K_ON_END, v).apply();
    }

    public int getSort() {
        return sp.getInt(K_SORT, SORT_NAME);
    }

    public void setSort(int v) {
        sp.edit().putInt(K_SORT, v).apply();
    }

    public int getGridSize() {
        return sp.getInt(K_GRID, GRID_MEDIUM);
    }

    public void setGridSize(int v) {
        sp.edit().putInt(K_GRID, v).apply();
    }

    /** Whether the app asks Android to pin itself, which blocks home, recents and the notification shade. */
    public boolean getLockApp() {
        return sp.getBoolean(K_LOCK, true);
    }

    public void setLockApp(boolean v) {
        sp.edit().putBoolean(K_LOCK, v).apply();
    }

    public boolean isLibraryDirty() {
        return sp.getBoolean(K_DIRTY, true);
    }

    public void setLibraryDirty(boolean v) {
        sp.edit().putBoolean(K_DIRTY, v).apply();
    }

    /** Column count for the current grid size: large 1/2, medium 2/3, small 3/4 (portrait/landscape). */
    public int columns(boolean landscape) {
        switch (getGridSize()) {
            case GRID_LARGE:
                return landscape ? 2 : 1;
            case GRID_SMALL:
                return landscape ? 4 : 3;
            case GRID_MEDIUM:
            default:
                return landscape ? 3 : 2;
        }
    }
}
