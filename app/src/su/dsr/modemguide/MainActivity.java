package su.dsr.modemguide;

import android.app.Activity;
import android.graphics.Color;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

/**
 * Manual control screen: the modem/network-priority script runs only when the user presses
 * "Run now", never automatically on boot or in the background. "Log" / "Status" just read
 * back what happened, so every action taken on the device is visible here.
 */
public class MainActivity extends Activity {

    private TextView log;
    private final Handler ui = new Handler(Looper.getMainLooper());

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setPadding(24, 24, 24, 24);

        TextView version = new TextView(this);
        version.setText("ModemGuide " + versionName());
        version.setTextColor(Color.GRAY);
        version.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12);
        root.addView(version);

        LinearLayout buttons = new LinearLayout(this);
        buttons.setOrientation(LinearLayout.HORIZONTAL);
        buttons.addView(button("Run now", new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                append("running...");
                background(new Runnable() {
                    @Override
                    public void run() {
                        final String out = Keeper.run(MainActivity.this);
                        post(out);
                    }
                });
            }
        }));
        buttons.addView(button("Log", new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                background(new Runnable() {
                    @Override
                    public void run() {
                        post(Keeper.readLog(MainActivity.this, 40));
                    }
                });
            }
        }));
        buttons.addView(button("Status", new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                background(new Runnable() {
                    @Override
                    public void run() {
                        post(Keeper.status(MainActivity.this));
                    }
                });
            }
        }));
        root.addView(buttons);

        log = new TextView(this);
        log.setTextSize(TypedValue.COMPLEX_UNIT_SP, 15);
        log.setTextColor(Color.WHITE);
        log.setTextIsSelectable(true);
        log.setGravity(Gravity.TOP);
        ScrollView sv = new ScrollView(this);
        sv.addView(log);
        root.addView(sv);
        root.setBackgroundColor(Color.BLACK);

        setContentView(root);

        append("ready. adbd target " + Keeper.ADB_HOST + ":" + Keeper.ADB_PORT);
        append("manual mode: nothing runs until you press Run now.");
    }

    private String versionName() {
        try {
            return getPackageManager().getPackageInfo(getPackageName(), 0).versionName;
        } catch (Exception e) {
            return "?";
        }
    }

    private Button button(String text, View.OnClickListener l) {
        Button b = new Button(this);
        b.setText(text);
        b.setOnClickListener(l);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT);
        lp.setMargins(0, 0, dp(16), 0);
        b.setLayoutParams(lp);
        return b;
    }

    private int dp(int v) {
        return (int) TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v, getResources().getDisplayMetrics());
    }

    private void background(Runnable r) {
        new Thread(r, "ui-work").start();
    }

    private void post(final String text) {
        ui.post(new Runnable() {
            @Override
            public void run() {
                append(text);
            }
        });
    }

    private void append(String text) {
        log.append(text + "\n");
    }
}
