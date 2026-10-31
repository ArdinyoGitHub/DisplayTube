package com.displaytube.receiver;

import android.app.Activity;
import android.graphics.Color;
import android.os.Bundle;
import android.view.Gravity;
import android.view.SurfaceHolder;
import android.view.SurfaceView;
import android.view.View;
import android.view.WindowManager;
import android.widget.FrameLayout;
import android.widget.TextView;

/**
 * Tam ekran alici. PC'deki DisplayTubeServer'a 127.0.0.1:27183 uzerinden
 * (adb reverse ile USB) baglanir, H.264 akisini SurfaceView'a cizer.
 */
public class MainActivity extends Activity implements SurfaceHolder.Callback, StreamClient.Listener {

    static final String HOST = "127.0.0.1";
    static final int PORT = 27183;

    private SurfaceView surfaceView;
    private TextView status;
    private StreamClient client;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        if (android.os.Build.VERSION.SDK_INT >= 28) {
            // Kamera centiginin oldugu kenara da ciz; aksi halde goruntu ~%3 daralir.
            WindowManager.LayoutParams lp = getWindow().getAttributes();
            lp.layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES;
            getWindow().setAttributes(lp);
        }

        FrameLayout root = new FrameLayout(this);
        root.setBackgroundColor(Color.BLACK);

        surfaceView = new SurfaceView(this);
        surfaceView.getHolder().addCallback(this);
        root.addView(surfaceView, new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT));

        status = new TextView(this);
        status.setTextColor(Color.LTGRAY);
        status.setTextSize(18);
        status.setGravity(Gravity.CENTER);
        root.addView(status, new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT));

        setContentView(root);
        hideSystemUi();
        onStatus("PC bekleniyor...\nUSB ile bagla ve PC'de pc\\stream.ps1 calistir.");
    }

    @Override
    public void onWindowFocusChanged(boolean hasFocus) {
        super.onWindowFocusChanged(hasFocus);
        if (hasFocus) hideSystemUi();
    }

    @SuppressWarnings("deprecation")
    private void hideSystemUi() {
        getWindow().getDecorView().setSystemUiVisibility(
                View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
                        | View.SYSTEM_UI_FLAG_FULLSCREEN
                        | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                        | View.SYSTEM_UI_FLAG_LAYOUT_STABLE
                        | View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
                        | View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN);
    }

    @Override
    public void surfaceCreated(SurfaceHolder holder) {
        client = new StreamClient(HOST, PORT, holder.getSurface(), this);
        client.start();
    }

    @Override
    public void surfaceChanged(SurfaceHolder holder, int format, int width, int height) { }

    @Override
    public void surfaceDestroyed(SurfaceHolder holder) {
        if (client != null) {
            client.stop();
            client = null;
        }
    }

    // StreamClient.Listener (arka plan thread'inden cagrilir)
    @Override
    public void onStatus(final String text) {
        runOnUiThread(new Runnable() {
            @Override public void run() {
                status.setText(text);
                status.setVisibility(text == null ? View.GONE : View.VISIBLE);
            }
        });
    }
}
