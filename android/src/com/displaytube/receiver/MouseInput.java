package com.displaytube.receiver;

import android.os.Handler;
import android.os.Looper;
import android.view.HapticFeedbackConstants;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewConfiguration;

/**
 * Fare kipi: dokunmatik hareketleri fare olaylarina cevirir (UI thread'inde calisir).
 *   dokun                 -> sol tik
 *   basili tut            -> sag tik (titresimle haber verir)
 *   surukle               -> sol tus basili surukleme
 *   iki parmakla kaydir   -> tekerlek (dogal yon, yatay da)
 *   iki parmakla dokun    -> sag tik
 * Konum her zaman parmagin altidir (dokunmatik ekran gibi), imlec parmagi izler.
 */
final class MouseInput {

    interface Sink { void sendMouse(int buttons, int x, int y, int wheelV, int wheelH); }

    static final int LEFT = 1, RIGHT = 2;

    private static final int IDLE = 0, PENDING = 1, DRAG = 2, LONG = 3, SCROLL = 4, DONE = 5;
    private static final int TWO_FINGER_TAP_MS = 250;

    private final Handler handler = new Handler(Looper.getMainLooper());
    private final int slop, longPressMs;
    private final float scrollStepPx;     // bu kadar parmak hareketi = 1 tekerlek centigi

    private Sink sink;
    private View view;
    private int state = IDLE;
    private float downX, downY;           // view koordinatlari
    private float lastCx, lastCy;         // iki parmak merkezi
    private float scrollRestX, scrollRestY;
    private boolean scrollMoved;
    private long twoDownTime;
    private float anchorX, anchorY;       // kaydirma sirasinda imlec burada durur

    MouseInput(View v) {
        view = v;
        ViewConfiguration vc = ViewConfiguration.get(v.getContext());
        slop = vc.getScaledTouchSlop();
        longPressMs = ViewConfiguration.getLongPressTimeout();
        scrollStepPx = 24 * v.getResources().getDisplayMetrics().density;
    }

    private final Runnable longPress = new Runnable() {
        @Override public void run() {
            if (state != PENDING) return;
            state = LONG;
            send(RIGHT, downX, downY);
            send(0, downX, downY);
            view.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS);
        }
    };

    void onTouch(MotionEvent e, Sink s) {
        sink = s;
        switch (e.getActionMasked()) {
            case MotionEvent.ACTION_DOWN:
                state = PENDING;
                downX = e.getX();
                downY = e.getY();
                send(0, downX, downY);                 // imleci parmagin altina getir
                handler.postDelayed(longPress, longPressMs);
                break;

            case MotionEvent.ACTION_POINTER_DOWN:
                handler.removeCallbacks(longPress);
                if (state == DRAG) send(0, e.getX(0), e.getY(0));   // suruklemeyi birak
                if (state == PENDING || state == DRAG || state == LONG) {
                    state = SCROLL;
                    centroid(e);
                    anchorX = lastCx;
                    anchorY = lastCy;
                    scrollRestX = scrollRestY = 0;
                    scrollMoved = false;
                    twoDownTime = e.getEventTime();
                }
                break;

            case MotionEvent.ACTION_MOVE:
                onMove(e);
                break;

            case MotionEvent.ACTION_POINTER_UP:
                if (state == SCROLL) {
                    if (!scrollMoved && e.getEventTime() - twoDownTime < TWO_FINGER_TAP_MS) {
                        send(RIGHT, anchorX, anchorY);
                        send(0, anchorX, anchorY);
                    }
                    state = DONE;   // kalan parmak kalkana kadar bir sey yapma
                }
                break;

            case MotionEvent.ACTION_UP:
                handler.removeCallbacks(longPress);
                if (state == PENDING) {                // kisa dokunus = tik
                    send(LEFT, downX, downY);
                    send(0, downX, downY);
                } else if (state == DRAG) {
                    send(0, e.getX(), e.getY());
                }
                state = IDLE;
                break;

            case MotionEvent.ACTION_CANCEL:
                handler.removeCallbacks(longPress);
                if (state == DRAG) send(0, e.getX(), e.getY());
                state = IDLE;
                break;
        }
    }

    private void onMove(MotionEvent e) {
        float x = e.getX(), y = e.getY();
        switch (state) {
            case PENDING:
                if (Math.abs(x - downX) > slop || Math.abs(y - downY) > slop) {
                    handler.removeCallbacks(longPress);
                    state = DRAG;
                    send(LEFT, downX, downY);           // basma noktasi: surukleme oradan baslar
                    send(LEFT, x, y);
                }
                break;
            case DRAG:
                send(LEFT, x, y);
                break;
            case LONG:
                send(0, x, y);                          // sag tik menusunde gezinme
                break;
            case SCROLL:
                if (e.getPointerCount() < 2) break;
                float px = lastCx, py = lastCy;
                centroid(e);
                scrollRestX += lastCx - px;
                scrollRestY += lastCy - py;
                if (Math.abs(lastCx - anchorX) > slop || Math.abs(lastCy - anchorY) > slop) scrollMoved = true;
                if (!scrollMoved) break;
                // Dogal yon: parmaklar asagi -> icerik asagi (yukari kaydirma = pozitif tekerlek)
                int wv = Math.round(scrollRestY * 120f / scrollStepPx);
                int wh = Math.round(-scrollRestX * 120f / scrollStepPx);
                if (wv != 0 || wh != 0) {
                    scrollRestY -= wv * scrollStepPx / 120f;
                    scrollRestX += wh * scrollStepPx / 120f;
                    sink.sendMouse(0, nx(anchorX), ny(anchorY), clamp16(wv), clamp16(wh));
                }
                break;
            default:
                break;
        }
    }

    private void centroid(MotionEvent e) {
        float sx = 0, sy = 0;
        int n = Math.min(e.getPointerCount(), 2);
        for (int i = 0; i < n; i++) { sx += e.getX(i); sy += e.getY(i); }
        lastCx = sx / n;
        lastCy = sy / n;
    }

    private void send(int buttons, float x, float y) {
        sink.sendMouse(buttons, nx(x), ny(y), 0, 0);
    }

    private int nx(float x) { return norm(x, view.getWidth()); }
    private int ny(float y) { return norm(y, view.getHeight()); }

    private static int norm(float v, int size) {
        if (size <= 1) return 0;
        int r = Math.round(v * 65535f / (size - 1));
        return r < 0 ? 0 : (r > 65535 ? 65535 : r);
    }

    private static int clamp16(int v) { return v < -32768 ? -32768 : (v > 32767 ? 32767 : v); }
}
