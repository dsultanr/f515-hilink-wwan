#!/bin/bash
# Builds F515HilinkWwanApp.apk without gradle: aapt2 -> javac -> d8 -> zipalign -> apksigner.
set -euo pipefail

SDK=/home/dsultanr/android-sdk
BT=$SDK/android-14
PLATFORM=$SDK/android-11/android.jar
PROJ=$(cd "$(dirname "$0")" && pwd)
OUT=$PROJ/build
APK=$PROJ/F515HilinkWwanApp.apk

mkdir -p "$OUT/classes"
mkdir -p "$OUT/dex"
mkdir -p "$OUT/res-compiled"

echo "== aapt2 compile (res)"
"$BT/aapt2" compile --dir "$PROJ/res" -o "$OUT/res-compiled"

echo "== aapt2 link (manifest + assets + res)"
"$BT/aapt2" link \
    --manifest "$PROJ/AndroidManifest.xml" \
    -I "$PLATFORM" \
    -A "$PROJ/assets" \
    -R "$OUT"/res-compiled/*.flat \
    --min-sdk-version 26 --target-sdk-version 29 \
    -o "$OUT/base.apk"

echo "== javac"
find "$PROJ/src" -name '*.java' > "$OUT/sources.txt"
javac -source 8 -target 8 -nowarn \
    -bootclasspath "$PLATFORM" \
    -d "$OUT/classes" @"$OUT/sources.txt" 2>&1 | grep -v 'bootstrap class path' || true

echo "== d8"
"$BT/d8" --min-api 26 --output "$OUT/dex" \
    $(find "$OUT/classes" -name '*.class')

echo "== package"
cp "$OUT/base.apk" "$OUT/unsigned.apk"
(cd "$OUT/dex" && zip -q -X "$OUT/unsigned.apk" classes.dex)

echo "== zipalign + sign"
# keystore.jks уже существует (store-пароль "modemguide", от старого имени приложения -
# менять пароль существующего файла нельзя, это уничтожило бы прежнюю запись). Новый
# alias с собственным паролем ключа просто добавляется в тот же файл, старый не трогается.
STORE_PASS=modemguide
KEY_ALIAS=f515hilinkwwan
if [ ! -f "$PROJ/keystore.jks" ]; then
    keytool -genkeypair -keystore "$PROJ/keystore.jks" -alias "$KEY_ALIAS" \
        -storepass "$STORE_PASS" -keypass "$KEY_ALIAS" -keyalg RSA -keysize 2048 \
        -validity 10000 -dname "CN=F515HilinkWwanApp, O=f515, C=RU" >/dev/null 2>&1
    echo "   (created keystore.jks)"
elif ! keytool -list -keystore "$PROJ/keystore.jks" -storepass "$STORE_PASS" -alias "$KEY_ALIAS" >/dev/null 2>&1; then
    keytool -genkeypair -keystore "$PROJ/keystore.jks" -alias "$KEY_ALIAS" \
        -storepass "$STORE_PASS" -keypass "$KEY_ALIAS" -keyalg RSA -keysize 2048 \
        -validity 10000 -dname "CN=F515HilinkWwanApp, O=f515, C=RU" >/dev/null 2>&1
    echo "   (added $KEY_ALIAS key to keystore.jks)"
fi
"$BT/zipalign" -f -p 4 "$OUT/unsigned.apk" "$OUT/aligned.apk"
# PKCS12-хранилища (формат этого keystore.jks) не поддерживают отдельный пароль на
# запись - реально шифруют её паролем самого хранилища, каким бы -keypass ни задавался
# при создании. Поэтому key-pass здесь тоже STORE_PASS, а не пароль alias'а.
"$BT/apksigner" sign --ks "$PROJ/keystore.jks" --ks-pass pass:"$STORE_PASS" \
    --ks-key-alias "$KEY_ALIAS" --key-pass pass:"$STORE_PASS" \
    --v1-signing-enabled true --v2-signing-enabled true \
    --out "$APK" "$OUT/aligned.apk"

echo "== done"
ls -la "$APK"
"$BT/apksigner" verify --print-certs "$APK" | head -3
