package su.dsr.f515hilinkwwan;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.DialogInterface;
import android.content.Intent;
import android.graphics.Color;
import android.net.Uri;
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

import java.util.ArrayList;
import java.util.List;

/**
 * modem-up.sh does all the real work (idempotent, self-checking with --check) - this
 * screen just deploys it and runs it. Nothing runs automatically: only on button press.
 */
public class MainActivity extends Activity {

    private static final String SPEEDTEST_URL = "https://internet.yandex.ru";

    private TextView log;
    private LinearLayout buttonsRow;
    private final Handler ui = new Handler(Looper.getMainLooper());
    private boolean busy = false;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setPadding(24, 24, 24, 24);
        root.setBackgroundColor(Color.BLACK);

        TextView version = new TextView(this);
        version.setText("F515 HiLink WWAN " + versionName());
        version.setTextColor(Color.GRAY);
        version.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12);
        root.addView(version);

        buttonsRow = new LinearLayout(this);
        buttonsRow.setOrientation(LinearLayout.HORIZONTAL);
        addRunButton("Проверка", "--check");
        addRunButton("Включить", "");
        addUrlButton("Интернетометр", SPEEDTEST_URL);
        addFormatButton();
        ScrollView buttonsScroll = new ScrollView(this);
        buttonsScroll.setHorizontalScrollBarEnabled(false);
        buttonsScroll.addView(buttonsRow);
        root.addView(buttonsScroll);

        log = new TextView(this);
        log.setTextSize(TypedValue.COMPLEX_UNIT_SP, 15);
        log.setTextColor(Color.WHITE);
        log.setTextIsSelectable(true);
        log.setGravity(Gravity.TOP);
        ScrollView sv = new ScrollView(this);
        sv.addView(log);
        root.addView(sv);

        setContentView(root);

        append("ready. adbd target " + Keeper.ADB_HOST + ":" + Keeper.ADB_PORT);
        append("ничего не запускается само - только по кнопке.");
        append("");
        append("Проверка          - только диагностика, ничего не меняет");
        append("Включить          - поднять USB-модем как WAN и починить DNS фантомной сети");
        append("Интернетометр     - открыть " + SPEEDTEST_URL + " (проверка интернета глазами)");
        append("Форматировать SD  - выбрать и стереть SD/TF-карту (необратимо)");
    }

    private void addRunButton(String text, final String args) {
        buttonsRow.addView(button(text, new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                if (busy) return;
                setBusy(true);
                append("");
                append("> " + text + " ...");
                background(new Runnable() {
                    @Override
                    public void run() {
                        final String out = Keeper.run(MainActivity.this, args);
                        post(out);
                        ui.post(new Runnable() {
                            @Override
                            public void run() {
                                setBusy(false);
                            }
                        });
                    }
                });
            }
        }));
    }

    /**
     * Форматирование - деструктивная операция, поэтому в отличие от остальных кнопок
     * ничего не запускает сразу: сначала опрашивает format-sdcard.sh --list (безопасно,
     * ничего не меняет), затем пользователь явно выбирает устройство и подтверждает.
     * Никакого автовыбора "самой вероятной" карты - список показывает vendor/model/размер,
     * решает человек.
     */
    private void addFormatButton() {
        buttonsRow.addView(button("Форматировать SD", new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                if (busy) return;
                setBusy(true);
                append("");
                append("> Форматировать SD: ищу карты...");
                background(new Runnable() {
                    @Override
                    public void run() {
                        final String out = Keeper.runFormat(MainActivity.this, "--list");
                        final List<String[]> devices = parseDevices(out);
                        ui.post(new Runnable() {
                            @Override
                            public void run() {
                                if (devices.isEmpty()) {
                                    append("устройства не найдены (или ошибка):");
                                    append(out);
                                    setBusy(false);
                                } else {
                                    showDeviceChooser(devices);
                                }
                            }
                        });
                    }
                });
            }
        }));
    }

    /** Строки вида "sdb|HUAWEI|TF CARD Storage|14.5G|exfat|" из format-sdcard.sh --list. */
    private List<String[]> parseDevices(String out) {
        List<String[]> result = new ArrayList<>();
        for (String line : out.split("\n")) {
            String[] p = line.split("\\|", -1);
            if (p.length >= 6 && p[0].matches("sd[a-z]")) {
                result.add(p);
            }
        }
        return result;
    }

    /**
     * Один диалог: радио-список карт + кнопка "Форматировать" - выбор и запуск разделены,
     * тап по строке списка сам по себе ничего не запускает. После нажатия "Форматировать"
     * идёт ещё один диалог-подтверждение (см. confirmFormat) - это уже финальный шаг.
     */
    private void showDeviceChooser(final List<String[]> devices) {
        final String[] labels = new String[devices.size()];
        for (int i = 0; i < devices.size(); i++) {
            String[] d = devices.get(i);
            String vendor = d[1].trim();
            String model = d[2].trim();
            String size = d[3].trim();
            String fstype = d[4].trim();
            labels[i] = d[0] + " - " + vendor + " " + model + ", " + size +
                    (fstype.isEmpty() ? "" : ", сейчас " + fstype);
        }
        final int[] selected = {0};
        new AlertDialog.Builder(this)
                .setTitle("Какую карту форматировать?")
                .setSingleChoiceItems(labels, 0, new DialogInterface.OnClickListener() {
                    @Override
                    public void onClick(DialogInterface dialog, int which) {
                        selected[0] = which;
                    }
                })
                .setPositiveButton("Форматировать", new DialogInterface.OnClickListener() {
                    @Override
                    public void onClick(DialogInterface dialog, int which) {
                        confirmFormat(devices.get(selected[0]));
                    }
                })
                .setNegativeButton("Отмена", new DialogInterface.OnClickListener() {
                    @Override
                    public void onClick(DialogInterface dialog, int which) {
                        append("отменено.");
                        setBusy(false);
                    }
                })
                .setOnCancelListener(new DialogInterface.OnCancelListener() {
                    @Override
                    public void onCancel(DialogInterface dialog) {
                        append("отменено.");
                        setBusy(false);
                    }
                })
                .show();
    }

    private void confirmFormat(final String[] dev) {
        final String name = dev[0];
        String vendor = dev[1].trim();
        String model = dev[2].trim();
        String size = dev[3].trim();
        new AlertDialog.Builder(this)
                .setTitle("Стереть " + name + "?")
                .setMessage(vendor + " " + model + ", " + size +
                        "\n\nВСЕ данные на этой карте будут уничтожены безвозвратно.")
                .setPositiveButton("Стереть", new DialogInterface.OnClickListener() {
                    @Override
                    public void onClick(DialogInterface dialog, int which) {
                        runFormat(name);
                    }
                })
                .setNegativeButton("Отмена", new DialogInterface.OnClickListener() {
                    @Override
                    public void onClick(DialogInterface dialog, int which) {
                        append("отменено.");
                        setBusy(false);
                    }
                })
                .setOnCancelListener(new DialogInterface.OnCancelListener() {
                    @Override
                    public void onCancel(DialogInterface dialog) {
                        append("отменено.");
                        setBusy(false);
                    }
                })
                .show();
    }

    private void runFormat(final String dev) {
        append("> форматирую " + dev + "...");
        background(new Runnable() {
            @Override
            public void run() {
                final String out = Keeper.runFormat(MainActivity.this, "--format=" + dev);
                post(out);
                ui.post(new Runnable() {
                    @Override
                    public void run() {
                        setBusy(false);
                    }
                });
            }
        });
    }

    /**
     * Открывает URL системным обработчиком ACTION_VIEW - на этой прошивке уже есть
     * готовый webview-просмотрщик, поднимать второй смысла нет.
     */
    private void addUrlButton(String text, final String url) {
        buttonsRow.addView(button(text, new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                try {
                    startActivity(new Intent(Intent.ACTION_VIEW, Uri.parse(url)));
                } catch (Exception e) {
                    append("не удалось открыть " + url + ": " + e);
                }
            }
        }));
    }

    private void setBusy(boolean b) {
        busy = b;
        for (int i = 0; i < buttonsRow.getChildCount(); i++) {
            buttonsRow.getChildAt(i).setEnabled(!b);
        }
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
        lp.setMargins(0, 0, dp(12), 0);
        b.setLayoutParams(lp);
        return b;
    }

    private int dp(int v) {
        return (int) TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v, getResources().getDisplayMetrics());
    }

    private void background(Runnable r) {
        new Thread(r, "f515hilinkwwan-work").start();
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
