package dev.jesserockz.littlevideos;

import android.content.ContentResolver;
import android.content.Context;
import android.content.UriPermission;
import android.database.Cursor;
import android.net.Uri;
import android.provider.DocumentsContract;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.Comparator;
import java.util.HashSet;
import java.util.LinkedList;
import java.util.List;
import java.util.Set;

/** Enumerates videos under a SAF tree using DocumentsContract only (no AndroidX DocumentFile). */
public final class VideoLibrary {
    /** Thrown when the root of the tree cannot be listed (permission revoked, folder gone, ...). */
    public static final class AccessException extends RuntimeException {
        private static final long serialVersionUID = 1L;

        public AccessException(String msg, Throwable cause) {
            super(msg, cause);
        }
    }

    private static final int MAX_DEPTH = 8;
    private static final int MAX_ITEMS = 2000;

    private static final String[] PROJECTION = {
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_SIZE,
            DocumentsContract.Document.COLUMN_LAST_MODIFIED,
    };

    private static final Set<String> VIDEO_EXTENSIONS = new HashSet<>(Arrays.asList(
            "mp4", "mkv", "webm", "m4v", "mov", "avi", "3gp", "3g2", "ts", "m2ts", "mts",
            "mpg", "mpeg", "mpe", "ogv", "flv", "wmv", "asf", "divx"));

    private static volatile List<VideoItem> current = Collections.emptyList();

    private VideoLibrary() {
    }

    /** Process-lifetime list shared with PlayerActivity (avoids the Intent binder size limit). */
    public static void setCurrent(List<VideoItem> list) {
        current = list == null ? Collections.<VideoItem>emptyList() : list;
    }

    public static List<VideoItem> current() {
        return current;
    }

    private static final class Node {
        final String docId;
        final int depth;

        Node(String docId, int depth) {
            this.docId = docId;
            this.depth = depth;
        }
    }

    /** Never call on the main thread. Throws AccessException if the root folder cannot be read. */
    public static List<VideoItem> scan(Context ctx, Uri treeUri, boolean recurse, int sort) {
        ContentResolver cr = ctx.getApplicationContext().getContentResolver();
        List<VideoItem> out = new ArrayList<>();
        LinkedList<Node> queue = new LinkedList<>();
        Set<String> seen = new HashSet<>();
        String rootId;
        try {
            rootId = DocumentsContract.getTreeDocumentId(treeUri);
        } catch (RuntimeException e) {
            throw new AccessException("Not a tree uri", e);
        }
        queue.add(new Node(rootId, 0));
        seen.add(rootId);
        boolean isRoot = true;
        while (!queue.isEmpty() && out.size() < MAX_ITEMS) {
            Node n = queue.removeFirst();
            try {
                listChildren(cr, treeUri, n, recurse, queue, seen, out);
            } catch (Exception e) {
                // An unreadable subfolder is skipped; an unreadable root means no access at all.
                if (isRoot) {
                    throw new AccessException("Cannot list root", e);
                }
            }
            isRoot = false;
        }
        sortItems(out, sort);
        return out;
    }

    private static void listChildren(ContentResolver cr, Uri treeUri, Node n, boolean recurse,
                                     LinkedList<Node> queue, Set<String> seen, List<VideoItem> out) {
        Uri childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, n.docId);
        Cursor c = null;
        try {
            c = cr.query(childrenUri, PROJECTION, null, null, null);
            if (c == null) {
                throw new IllegalStateException("null cursor");
            }
            while (c.moveToNext() && out.size() < MAX_ITEMS) {
                try {
                    String docId = c.getString(0);
                    String name = c.getString(1);
                    String mime = c.getString(2);
                    if (docId == null) {
                        continue;
                    }
                    if (DocumentsContract.Document.MIME_TYPE_DIR.equals(mime)) {
                        if (recurse && n.depth < MAX_DEPTH && seen.add(docId)) {
                            queue.add(new Node(docId, n.depth + 1));
                        }
                    } else if (isVideo(mime, name)) {
                        long size = c.isNull(3) ? 0 : c.getLong(3);
                        long modified = c.isNull(4) ? 0 : c.getLong(4);
                        Uri uri = DocumentsContract.buildDocumentUriUsingTree(treeUri, docId);
                        out.add(new VideoItem(uri, docId, name, size, modified));
                    }
                } catch (RuntimeException rowError) {
                    // One bad row must not abort the scan.
                }
            }
        } finally {
            if (c != null) {
                c.close();
            }
        }
    }

    /**
     * Providers often report a generic mime type for files they do not sniff (notably some
     * network and USB providers), so for those we fall back to the file extension.
     */
    static boolean isVideo(String mime, String name) {
        if (mime != null && mime.startsWith("video/")) {
            return true;
        }
        boolean generic = mime == null || mime.isEmpty()
                || "application/octet-stream".equals(mime) || "*/*".equals(mime);
        return generic && name != null && VIDEO_EXTENSIONS.contains(VideoItem.extensionOf(name));
    }

    static void sortItems(List<VideoItem> items, int sort) {
        Comparator<VideoItem> cmp;
        if (sort == Prefs.SORT_NEWEST) {
            cmp = (a, b) -> compareModified(a, b, false);
        } else if (sort == Prefs.SORT_OLDEST) {
            cmp = (a, b) -> compareModified(a, b, true);
        } else {
            cmp = (a, b) -> String.CASE_INSENSITIVE_ORDER.compare(a.title, b.title);
        }
        // Collections.sort is stable, so equal keys keep provider order.
        Collections.sort(items, cmp);
    }

    /** Unknown timestamps (0) always sort last, in either direction. */
    private static int compareModified(VideoItem a, VideoItem b, boolean ascending) {
        boolean aUnknown = a.lastModified <= 0;
        boolean bUnknown = b.lastModified <= 0;
        if (aUnknown || bUnknown) {
            return aUnknown == bUnknown ? 0 : (aUnknown ? 1 : -1);
        }
        int r = a.lastModified < b.lastModified ? -1 : (a.lastModified == b.lastModified ? 0 : 1);
        return ascending ? r : -r;
    }

    /** Whether we still hold a persisted read grant for exactly this tree. */
    public static boolean hasPermission(Context ctx, Uri treeUri) {
        try {
            for (UriPermission p : ctx.getContentResolver().getPersistedUriPermissions()) {
                if (p.isReadPermission() && p.getUri().equals(treeUri)) {
                    return true;
                }
            }
        } catch (RuntimeException e) {
            // fall through
        }
        return false;
    }

    /** Display name of the chosen folder. Does a provider query, so keep it off the main thread. */
    public static String folderName(Context ctx, Uri treeUri) {
        String id = null;
        try {
            id = DocumentsContract.getTreeDocumentId(treeUri);
            Uri doc = DocumentsContract.buildDocumentUriUsingTree(treeUri, id);
            Cursor c = null;
            try {
                c = ctx.getContentResolver().query(doc,
                        new String[]{DocumentsContract.Document.COLUMN_DISPLAY_NAME}, null, null, null);
                if (c != null && c.moveToFirst()) {
                    String n = c.getString(0);
                    if (n != null && !n.isEmpty()) {
                        return n;
                    }
                }
            } finally {
                if (c != null) {
                    c.close();
                }
            }
        } catch (RuntimeException e) {
            // fall back to the document id below
        }
        if (id == null) {
            return treeUri.getLastPathSegment() == null ? "" : treeUri.getLastPathSegment();
        }
        int cut = Math.max(id.lastIndexOf(':'), id.lastIndexOf('/'));
        String tail = cut >= 0 ? id.substring(cut + 1) : id;
        return tail.isEmpty() ? id : tail;
    }
}
