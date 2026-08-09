package su.dsr.f515hilinkwwan;

import android.content.Context;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;

/**
 * Everything that needs root goes through here: connect to the local adbd (which runs as
 * root on this build), redeploy modem-up.sh and run it. One shot, no daemon - the script
 * itself is idempotent, so pressing the button again is always safe.
 */
public class Keeper {

    static final String TMP = "/data/local/tmp";
    static final String SCRIPT = TMP + "/modem-up.sh";
    static final String ADB_HOST = "127.0.0.1";
    static final int ADB_PORT = 5555;

    private static final Object LOCK = new Object();

    /** Deploys modem-up.sh and runs it with the given arguments (e.g. "--check"). */
    public static String run(Context ctx, String args) {
        synchronized (LOCK) {
            StringBuilder sb = new StringBuilder();
            AdbClient adb = null;
            try {
                adb = connect(ctx, 15000);
                String uid = adb.shell("id -u").trim();
                sb.append("adb connected, uid=").append(uid).append('\n');
                if (!uid.startsWith("0")) {
                    sb.append("WARNING: adbd is not root, this will fail\n");
                }

                deployScript(ctx, adb, sb);

                String cmd = "sh " + SCRIPT + " " + args + " 2>&1";
                sb.append("--- ").append(cmd).append(" ---\n");
                sb.append(adb.shell(cmd));
            } catch (Exception e) {
                sb.append("failed: ").append(e).append('\n');
            } finally {
                if (adb != null) adb.close();
            }
            return sb.toString();
        }
    }

    private static AdbClient connect(Context ctx, int timeoutMs) throws Exception {
        return new AdbClient(ADB_HOST, ADB_PORT, asset(ctx, "adbkey"), asset(ctx, "adbkey.pub"), timeoutMs);
    }

    private static void deployScript(Context ctx, AdbClient adb, StringBuilder sb) throws Exception {
        byte[] data = asset(ctx, "modem-up.sh");
        String b64 = android.util.Base64.encodeToString(data, android.util.Base64.NO_WRAP);
        String out = adb.shell("echo '" + b64 + "' | base64 -d > " + SCRIPT +
                " && chmod 755 " + SCRIPT + " && echo ok").trim();
        sb.append("deploy modem-up.sh: ").append(out).append('\n');
    }

    private static byte[] asset(Context ctx, String name) throws Exception {
        InputStream is = ctx.getAssets().open(name);
        try {
            ByteArrayOutputStream bos = new ByteArrayOutputStream();
            byte[] buf = new byte[16384];
            int n;
            while ((n = is.read(buf)) > 0) bos.write(buf, 0, n);
            return bos.toByteArray();
        } finally {
            is.close();
        }
    }
}
