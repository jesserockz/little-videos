package io.github.jesserockz.littlevideos;

import android.content.Context;
import android.content.SharedPreferences;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Canvas;
import android.graphics.Matrix;
import android.graphics.Paint;
import android.graphics.Point;
import android.media.MediaMetadataRetriever;
import android.net.Uri;
import android.os.Handler;
import android.os.Looper;
import android.os.ParcelFileDescriptor;
import android.provider.DocumentsContract;
import android.util.LruCache;
import android.widget.ImageView;

import java.io.File;
import java.io.FileOutputStream;
import java.lang.ref.WeakReference;
import java.security.MessageDigest;
import java.util.Collections;
import java.util.List;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.ThreadFactory;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * Loads video thumbnails into ImageViews with a memory cache, a disk cache and a small worker
 * pool. Holds only the application Context, never an Activity.
 */
public final class ThumbnailLoader {
    private static ThumbnailLoader instance;

    public static synchronized ThumbnailLoader get(Context ctx) {
        if (instance == null) {
            instance = new ThumbnailLoader(ctx.getApplicationContext());
        }
        return instance;
    }

    private final Context app;
    private final LruCache<String, Bitmap> mem;
    private final ExecutorService pool;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final File dir;
    private final SharedPreferences durations;
    // Files that already failed once this process, so a broken video is not re-decoded on every bind.
    private final Set<String> failedThumbs = Collections.newSetFromMap(new ConcurrentHashMap<String, Boolean>());
    private final Set<String> failedDurations = Collections.newSetFromMap(new ConcurrentHashMap<String, Boolean>());

    private ThumbnailLoader(Context appContext) {
        app = appContext;
        int cacheBytes = (int) Math.min(Integer.MAX_VALUE, Runtime.getRuntime().maxMemory() / 8);
        mem = new LruCache<String, Bitmap>(cacheBytes) {
            @Override
            protected int sizeOf(String key, Bitmap value) {
                return value.getByteCount();
            }
        };
        final AtomicInteger n = new AtomicInteger();
        pool = Executors.newFixedThreadPool(
                Math.max(2, Runtime.getRuntime().availableProcessors() - 1),
                new ThreadFactory() {
                    @Override
                    public Thread newThread(Runnable r) {
                        Thread t = new Thread(r, "thumb-" + n.incrementAndGet());
                        t.setDaemon(true);
                        return t;
                    }
                });
        dir = new File(app.getCacheDir(), "thumbs");
        durations = app.getSharedPreferences("durations", Context.MODE_PRIVATE);
    }

    /** Everything one load() call needs, so the worker never touches an Activity. */
    private static final class Request {
        final VideoItem item;
        final String key;
        final int w;
        final int h;
        final WeakReference<ImageView> view;
        final Runnable onDurationKnown;

        Request(VideoItem item, String key, int w, int h, ImageView view, Runnable cb) {
            this.item = item;
            this.key = key;
            this.w = w;
            this.h = h;
            this.view = new WeakReference<>(view);
            this.onDurationKnown = cb;
        }

        /** The view is only ours to touch while its tag still equals our key. */
        boolean stillBound(ImageView v) {
            return v != null && key.equals(v.getTag());
        }
    }

    /** Fills in item.durationMs from the persisted store when known. Cheap, safe on any thread. */
    public void applyStoredDuration(VideoItem item) {
        if (item.durationMs < 0) {
            long d = durations.getLong(item.docId, -1);
            if (d > 0) {
                item.durationMs = d;
            }
        }
    }

    public void applyStoredDurations(List<VideoItem> items) {
        for (VideoItem it : items) {
            applyStoredDuration(it);
        }
    }

    /** Main thread. Caller should set its placeholder image first. */
    public void load(VideoItem item, ImageView view, int targetW, int targetH, Runnable onDurationKnown) {
        final String key = keyFor(item, targetW);
        // Recycling guard: a recycled row is re-tagged, so late results for the old item see a
        // different tag and are discarded instead of appearing on the wrong card.
        view.setTag(key);
        view.animate().cancel();
        view.setAlpha(1f);
        applyStoredDuration(item);

        Request req = new Request(item, key, targetW, targetH, view, onDurationKnown);
        Bitmap cached = mem.get(key);
        if (cached != null) {
            view.setImageBitmap(cached);
            if (item.durationMs < 0) {
                pool.execute(new DurationJob(req));
            }
            return;
        }
        pool.execute(new ThumbJob(req));
    }

    private final class ThumbJob implements Runnable {
        private final Request req;

        ThumbJob(Request req) {
            this.req = req;
        }

        @Override
        public void run() {
            try {
                // Skip work for rows that were scrolled past. A benign racy read of the tag.
                if (!req.stillBound(req.view.get())) {
                    return;
                }
                Bitmap bmp = null;
                if (!failedThumbs.contains(req.key)) {
                    bmp = loadOrCreate(req);
                    if (bmp == null) {
                        failedThumbs.add(req.key);
                    }
                }
                if (bmp != null) {
                    mem.put(req.key, bmp);
                    final Bitmap shown = bmp;
                    main.post(new Runnable() {
                        @Override
                        public void run() {
                            ImageView v = req.view.get();
                            if (req.stillBound(v)) {
                                v.setAlpha(0f);
                                v.setImageBitmap(shown);
                                v.animate().alpha(1f).setDuration(180).start();
                            }
                        }
                    });
                }
                if (req.item.durationMs < 0) {
                    probeDuration(req);
                }
            } catch (Throwable ignored) {
                // A broken file must never take the app down.
            }
        }
    }

    private final class DurationJob implements Runnable {
        private final Request req;

        DurationJob(Request req) {
            this.req = req;
        }

        @Override
        public void run() {
            try {
                if (req.item.durationMs < 0) {
                    probeDuration(req);
                }
            } catch (Throwable ignored) {
                // ignore
            }
        }
    }

    private Bitmap loadOrCreate(Request req) {
        File file = new File(dir, req.key + ".jpg");
        if (file.isFile() && file.length() > 0) {
            try {
                Bitmap b = BitmapFactory.decodeFile(file.getAbsolutePath());
                if (b != null) {
                    return b;
                }
            } catch (Throwable ignored) {
                // corrupt cache file: regenerate below
            }
            //noinspection ResultOfMethodCallIgnored
            file.delete();
        }
        Bitmap raw = providerThumbnail(req);
        if (raw == null) {
            raw = retrieverFrame(req);
        }
        if (raw == null) {
            return null;
        }
        Bitmap out = centerCrop(raw, req.w, req.h);
        if (out != raw) {
            raw.recycle();
        }
        writeJpeg(out, file);
        return out;
    }

    private Bitmap providerThumbnail(Request req) {
        try {
            return DocumentsContract.getDocumentThumbnail(
                    app.getContentResolver(), req.item.uri, new Point(req.w, req.h), null);
        } catch (Throwable t) {
            return null;
        }
    }

    /** Frame grab at 15% of the duration (or 1 s when unknown). Also records the duration. */
    private Bitmap retrieverFrame(Request req) {
        MediaMetadataRetriever mmr = new MediaMetadataRetriever();
        ParcelFileDescriptor pfd = null;
        try {
            pfd = app.getContentResolver().openFileDescriptor(req.item.uri, "r");
            if (pfd == null) {
                return null;
            }
            mmr.setDataSource(pfd.getFileDescriptor());
            long dur = parseDuration(mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION));
            if (dur > 0) {
                noteDuration(req, dur);
            }
            long timeUs = dur > 0 ? dur * 150L : 1_000_000L; // dur ms * 1000 us * 15%
            return mmr.getFrameAtTime(timeUs, MediaMetadataRetriever.OPTION_CLOSEST_SYNC);
        } catch (Throwable t) {
            return null;
        } finally {
            try {
                mmr.release();
            } catch (Throwable ignored) {
                // ignore
            }
            closeQuietly(pfd);
        }
    }

    /** Reads only the duration (no frame decode), for thumbnails that came from the provider. */
    private void probeDuration(Request req) {
        if (failedDurations.contains(req.item.docId)) {
            return;
        }
        MediaMetadataRetriever mmr = new MediaMetadataRetriever();
        ParcelFileDescriptor pfd = null;
        try {
            pfd = app.getContentResolver().openFileDescriptor(req.item.uri, "r");
            if (pfd != null) {
                mmr.setDataSource(pfd.getFileDescriptor());
                long dur = parseDuration(mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION));
                if (dur > 0) {
                    noteDuration(req, dur);
                    return;
                }
            }
            failedDurations.add(req.item.docId);
        } catch (Throwable t) {
            failedDurations.add(req.item.docId);
        } finally {
            try {
                mmr.release();
            } catch (Throwable ignored) {
                // ignore
            }
            closeQuietly(pfd);
        }
    }

    private void noteDuration(final Request req, long ms) {
        req.item.durationMs = ms;
        durations.edit().putLong(req.item.docId, ms).apply();
        if (req.onDurationKnown != null) {
            main.post(new Runnable() {
                @Override
                public void run() {
                    if (req.stillBound(req.view.get())) {
                        req.onDurationKnown.run();
                    }
                }
            });
        }
    }

    private static long parseDuration(String s) {
        if (s == null) {
            return -1;
        }
        try {
            return Long.parseLong(s.trim());
        } catch (NumberFormatException e) {
            return -1;
        }
    }

    private static void closeQuietly(ParcelFileDescriptor pfd) {
        if (pfd != null) {
            try {
                pfd.close();
            } catch (Throwable ignored) {
                // ignore
            }
        }
    }

    /** Scales the source to cover w x h and crops the overflow evenly from both sides. */
    private static Bitmap centerCrop(Bitmap src, int w, int h) {
        int sw = src.getWidth();
        int sh = src.getHeight();
        if (sw <= 0 || sh <= 0 || w <= 0 || h <= 0) {
            return src;
        }
        float scale = Math.max((float) w / sw, (float) h / sh);
        Bitmap out = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888);
        Matrix m = new Matrix();
        m.setScale(scale, scale);
        m.postTranslate((w - sw * scale) / 2f, (h - sh * scale) / 2f);
        Canvas c = new Canvas(out);
        c.drawBitmap(src, m, new Paint(Paint.FILTER_BITMAP_FLAG | Paint.ANTI_ALIAS_FLAG));
        return out;
    }

    private void writeJpeg(Bitmap bmp, File dest) {
        FileOutputStream os = null;
        File tmp = new File(dest.getParentFile(), dest.getName() + ".tmp");
        try {
            //noinspection ResultOfMethodCallIgnored
            dir.mkdirs();
            os = new FileOutputStream(tmp);
            boolean ok = bmp.compress(Bitmap.CompressFormat.JPEG, 85, os);
            os.close();
            os = null;
            // Rename so a concurrent reader never sees a half-written file.
            if (!ok || !tmp.renameTo(dest)) {
                //noinspection ResultOfMethodCallIgnored
                tmp.delete();
            }
        } catch (Throwable t) {
            //noinspection ResultOfMethodCallIgnored
            tmp.delete();
        } finally {
            if (os != null) {
                try {
                    os.close();
                } catch (Throwable ignored) {
                    // ignore
                }
            }
        }
    }

    /** Key changes when the file changes (lastModified) or the target size changes. */
    private static String keyFor(VideoItem item, int targetW) {
        String raw = item.docId + "|" + item.lastModified + "|" + targetW;
        try {
            byte[] d = MessageDigest.getInstance("SHA-1").digest(raw.getBytes("UTF-8"));
            StringBuilder sb = new StringBuilder(d.length * 2);
            for (byte b : d) {
                sb.append(Character.forDigit((b >> 4) & 0xF, 16)).append(Character.forDigit(b & 0xF, 16));
            }
            return sb.toString();
        } catch (Exception e) {
            return Integer.toHexString(raw.hashCode());
        }
    }

    /** Empties the memory cache, the disk cache and the stored durations. Do not call on the main thread. */
    public void clearCaches() {
        mem.evictAll();
        failedThumbs.clear();
        failedDurations.clear();
        File[] files = dir.listFiles();
        if (files != null) {
            for (File f : files) {
                //noinspection ResultOfMethodCallIgnored
                f.delete();
            }
        }
        //noinspection ResultOfMethodCallIgnored
        dir.delete();
        durations.edit().clear().apply();
    }
}
