package com.displaytube.receiver;

import android.app.Activity;
import android.graphics.Color;
import android.graphics.Typeface;
import android.os.Bundle;
import android.view.Gravity;
import android.view.SurfaceHolder;
import android.view.SurfaceView;
import android.view.View;
import android.view.WindowManager;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.TextView;

import java.util.Locale;

/**
 * Tam ekran alici. PC'deki DisplayTube'a 127.0.0.1:27183 uzerinden (adb reverse
 * ile USB) baglanir, H.264 akisini SurfaceView'a cizer. Goruntu yokken durum ekrani gosterir.
 */
public class MainActivity extends Activity implements SurfaceHolder.Callback, StreamClient.Listener {

    static final String HOST = "127.0.0.1";
    static final int PORT = 27183;

    private static final boolean TR = "tr".equals(Locale.getDefault().getLanguage());

    private SurfaceView surfaceView;
    private LinearLayout panel;
    private TextView statusText, hintText;
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

        // Durum ekrani: baslik, durum, ipucu
        panel = new LinearLayout(this);
        panel.setOrientation(LinearLayout.VERTICAL);
        panel.setGravity(Gravity.CENTER);
        panel.setBackgroundColor(Color.BLACK);

        TextView title = new TextView(this);
        title.setText("DisplayTube");
        title.setTextColor(Color.rgb(0, 150, 255));
        title.setTextSize(32);
        title.setTypeface(Typeface.DEFAULT_BOLD);
        title.setGravity(Gravity.CENTER);
        panel.addView(title);

        statusText = new TextView(this);
        statusText.setTextColor(Color.WHITE);
        statusText.setTextSize(20);
        statusText.setGravity(Gravity.CENTER);
        statusText.setPadding(0, 24, 0, 12);
        panel.addView(statusText);

        hintText = new TextView(this);
        hintText.setTextColor(Color.GRAY);
        hintText.setTextSize(14);
        hintText.setGravity(Gravity.CENTER);
        panel.addView(hintText);

        TextView version = new TextView(this);
        version.setText("v0.3");
        version.setTextColor(Color.DKGRAY);
        version.setTextSize(12);
        version.setGravity(Gravity.CENTER);
        version.setPadding(0, 32, 0, 0);
        panel.addView(version);

        root.addView(panel, new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT));

        setContentView(root);
        hideSystemUi();
        onState(StreamClient.STATE_WAITING_PC);
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
    public void onState(final int state) {
        runOnUiThread(new Runnable() {
            @Override public void run() {
                if (state == StreamClient.STATE_STREAMING) {
                    panel.setVisibility(View.GONE);
                    return;
                }
                panel.setVisibility(View.VISIBLE);
                if (state == StreamClient.STATE_CONNECTED) {
                    statusText.setText(TR ? "Bağlandı, görüntü bekleniyor..." : "Connected, waiting for video...");
                    hintText.setText("");
                } else {
                    statusText.setText(TR ? "Bilgisayar bekleniyor..." : "Waiting for computer...");
                    hintText.setText(TR
                            ? "Telefonu USB ile bilgisayara bağlayın ve bilgisayarda DisplayTube'u başlatın.\nUSB hata ayıklama açık olmalı."
                            : "Connect the phone to the computer over USB and start DisplayTube on the computer.\nUSB debugging must be enabled.");
                }
            }
        });
    }
}
