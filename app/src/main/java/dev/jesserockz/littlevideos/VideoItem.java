package dev.jesserockz.littlevideos;

import android.net.Uri;

import java.util.Locale;

/** Plain data holder for one video file found in the chosen folder. */
public final class VideoItem {
    public final Uri uri;
    public final String docId;
    public final String displayName;
    public final String title;
    public final long size;
    public final long lastModified;
    /** Milliseconds, or -1 when not yet known. Filled in lazily by ThumbnailLoader. */
    public volatile long durationMs = -1;

    public VideoItem(Uri uri, String docId, String displayName, long size, long lastModified) {
        this.uri = uri;
        this.docId = docId;
        this.displayName = displayName == null ? "" : displayName;
        this.title = makeTitle(this.displayName);
        this.size = size;
        this.lastModified = lastModified;
    }

    /** Strips the extension, turns '_' and '.' into spaces, collapses whitespace and trims. */
    static String makeTitle(String name) {
        String base = name;
        int dot = base.lastIndexOf('.');
        // Only treat a short trailing token as an extension ("a.b.mp4" -> "a.b").
        if (dot > 0 && base.length() - dot - 1 <= 5) {
            base = base.substring(0, dot);
        }
        String t = base.replace('_', ' ').replace('.', ' ').replaceAll("\\s+", " ").trim();
        return t.isEmpty() ? name.trim() : t;
    }

    static String extensionOf(String name) {
        int dot = name.lastIndexOf('.');
        if (dot < 0 || dot == name.length() - 1) {
            return "";
        }
        return name.substring(dot + 1).toLowerCase(Locale.ROOT);
    }
}
