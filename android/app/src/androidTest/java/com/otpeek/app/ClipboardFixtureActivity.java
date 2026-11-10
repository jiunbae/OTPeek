package com.otpeek.app;

import android.app.Activity;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Intent;
import android.os.Bundle;
import android.os.ResultReceiver;
import android.widget.TextView;

/** Separate test-APK UID, public fixture data only. Never included in release. */
public final class ClipboardFixtureActivity extends Activity {
    private boolean reported;
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        if ("finish".equals(getIntent().getAction())) { finish(); return; }
        TextView view = new TextView(this);
        view.setText("OTPeek public clipboard fixture");
        setContentView(view);
    }
    @Override public void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        if ("finish".equals(intent.getAction())) finish();
    }
    @Override public void onWindowFocusChanged(boolean focus) {
        super.onWindowFocusChanged(focus);
        if (!focus || reported || isFinishing()) return;
        reported = true;
        ClipboardManager manager = getSystemService(ClipboardManager.class);
        if (getIntent().getBooleanExtra("replace", false)) {
            manager.setPrimaryClip(ClipData.newPlainText("Public fixture", "public replacement"));
        }
        ClipData clip = manager.getPrimaryClip();
        String text = clip == null ? "" : clip.getItemAt(0).getText().toString();
        Bundle result = new Bundle();
        result.putBoolean("matches", getIntent().getStringExtra("expected").equals(text));
        ResultReceiver reply = getIntent().getParcelableExtra("reply");
        reply.send(0, result);
    }
}
