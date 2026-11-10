package com.otpeek.app;

import android.content.ContentProvider;
import android.content.ContentValues;
import android.database.Cursor;
import android.net.Uri;
import android.os.Bundle;
import android.os.ParcelFileDescriptor;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileNotFoundException;
import java.io.IOException;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

/** Test APK process has no target-app Kotlin runtime. Signature protected, fixture data only. */
public final class FixtureDocumentProvider extends ContentProvider {
    private final ConcurrentHashMap<String, CountDownLatch> waiting = new ConcurrentHashMap<>();
    private final AtomicInteger received = new AtomicInteger();
    private File file(String id) {
        UUID.fromString(id);
        return new File(getContext().getCacheDir(), "fixture-document-" + id);
    }
    @Override public boolean onCreate() { return true; }
    @Override public ParcelFileDescriptor openFile(Uri uri, String mode) throws FileNotFoundException {
        String kind = uri.getPathSegments().get(0);
        String id = uri.getPathSegments().get(1);
        File data = file(id);
        if (kind.equals("full")) return ParcelFileDescriptor.open(new File("/dev/full"), ParcelFileDescriptor.MODE_WRITE_ONLY);
        if (kind.equals("partial")) {
            received.set(0);
            try {
                ParcelFileDescriptor[] pipe = ParcelFileDescriptor.createReliablePipe();
                new Thread(() -> {
                    try {
                        received.set(new FileInputStream(pipe[0].getFileDescriptor()).read(new byte[64]));
                        pipe[0].closeWithError("Fixture partial write failure");
                    } catch (IOException ignored) { }
                }).start();
                return pipe[1];
            } catch (IOException error) { throw new FileNotFoundException("Fixture pipe unavailable"); }
        }
        if (kind.equals("slow") && mode.equals("r")) {
            try {
                ParcelFileDescriptor[] pipe = ParcelFileDescriptor.createReliablePipe();
                CountDownLatch gate = new CountDownLatch(1);
                waiting.put(id, gate);
                new Thread(() -> {
                    try (ParcelFileDescriptor.AutoCloseOutputStream output = new ParcelFileDescriptor.AutoCloseOutputStream(pipe[1]);
                         FileInputStream input = new FileInputStream(data)) {
                        byte[] prefix = new byte[8];
                        int count = input.read(prefix);
                        if (count > 0) output.write(prefix, 0, count);
                        gate.await(15, TimeUnit.SECONDS);
                        byte[] buffer = new byte[8192];
                        while ((count = input.read(buffer)) >= 0) output.write(buffer, 0, count);
                    } catch (Exception ignored) { /* cancellation closes the reader */ }
                    finally { waiting.remove(id); }
                }).start();
                return pipe[0];
            } catch (IOException error) { throw new FileNotFoundException("Fixture pipe unavailable"); }
        }
        if (!kind.equals("normal") && !kind.equals("slow")) throw new IllegalArgumentException("Unknown fixture mode");
        return ParcelFileDescriptor.open(data, mode.equals("r") ? ParcelFileDescriptor.MODE_READ_ONLY :
            ParcelFileDescriptor.MODE_CREATE | ParcelFileDescriptor.MODE_TRUNCATE | ParcelFileDescriptor.MODE_WRITE_ONLY);
    }
    @Override public Bundle call(String method, String arg, Bundle extras) {
        Bundle result = new Bundle();
        switch (method) {
            case "waiting": result.putBoolean("waiting", waiting.containsKey(arg)); break;
            case "release": if (waiting.containsKey(arg)) waiting.get(arg).countDown(); break;
            case "received": result.putInt("received", received.get()); break;
            case "delete": file(arg).delete(); break;
            default: throw new IllegalArgumentException("Unknown fixture command");
        }
        return result;
    }
    @Override public String getType(Uri uri) { return "application/octet-stream"; }
    @Override public Cursor query(Uri uri, String[] projection, String selection, String[] selectionArgs, String sortOrder) { return null; }
    @Override public Uri insert(Uri uri, ContentValues values) { throw new UnsupportedOperationException(); }
    @Override public int delete(Uri uri, String selection, String[] selectionArgs) { throw new UnsupportedOperationException(); }
    @Override public int update(Uri uri, ContentValues values, String selection, String[] selectionArgs) { throw new UnsupportedOperationException(); }
}
