#!/usr/bin/env bash
# Re-installs the *external* Android export toolchain (JDK 21, Android SDK,
# signing keystores). This lives outside the repo and is wiped whenever the
# sandbox is recycled, so re-run it before exporting the APK.
set -eu
GODOT=${GODOT:-/home/user/tools/Godot_v4.7.2-stable_linux.x86_64}
PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
JDK_DIR=/usr/lib/jvm/java-21-openjdk-amd64
SDK=/opt/android-sdk

echo "== JDK 21"
if [ ! -d "$JDK_DIR" ]; then sudo -n apt-get install -y openjdk-21-jdk-headless; fi
export JAVA_HOME=$JDK_DIR

echo "== Android SDK at $SDK"
if [ ! -x "$SDK/cmdline-tools/latest/bin/sdkmanager" ]; then
  sudo -n mkdir -p "$SDK/cmdline-tools"
  curl -sL -o /tmp/cmdtools.zip https://dl.google.com/android/repository/commandlinetools-linux-13114758_latest.zip
  sudo -n unzip -q -o /tmp/cmdtools.zip -d "$SDK/cmdline-tools"
  sudo -n mv "$SDK/cmdline-tools/cmdline-tools" "$SDK/cmdline-tools/latest"
  sudo -n chown -R "$(id -un):$(id -gn)" "$SDK"
fi
export ANDROID_HOME=$SDK
yes | "$SDK/cmdline-tools/latest/bin/sdkmanager" --sdk_root="$SDK" --licenses >/dev/null 2>&1 || true
"$SDK/cmdline-tools/latest/bin/sdkmanager" --sdk_root="$SDK" \
  "platform-tools" "build-tools;34.0.0" "platforms;android-34" >/dev/null

echo "== keystores"
mkdir -p /home/user/.local/share/godot/keystores "$PROJECT/build"
if [ ! -f "$PROJECT/build/eight_pages_release.keystore" ]; then
  keytool -genkeypair -v -keystore "$PROJECT/build/eight_pages_release.keystore" \
    -alias eightpages -keyalg RSA -keysize 2048 -validity 10000 \
    -storepass eightpages -keypass eightpages \
    -dname "CN=Eight Pages, OU=Game, O=Arena, L=Repino, S=SPb, C=RU"
fi
if [ ! -f /home/user/.local/share/godot/keystores/debug.keystore ]; then
  keytool -genkeypair -v -keystore /home/user/.local/share/godot/keystores/debug.keystore \
    -alias androiddebugkey -keyalg RSA -keysize 2048 -validity 10000 \
    -storepass android -keypass android -dname "CN=Android Debug, O=Android, C=US"
fi

echo "== editor settings"
python3 - <<'PY'
p = '/home/user/.config/godot/editor_settings-4.7.tres'
try:
    s = open(p).read()
except FileNotFoundError:
    print("  (no editor_settings, skipping)")
else:
    s = s.replace('export/android/java_sdk_path = ""',
                  'export/android/java_sdk_path = "/usr/lib/jvm/java-21-openjdk-amd64"')
    s = s.replace('export/android/android_sdk_path = "/home/user/Android/Sdk"',
                  'export/android/android_sdk_path = "/opt/android-sdk"')
    s = s.replace('export/android/debug_keystore = "~/.android/debug.keystore"',
                  'export/android/debug_keystore = "/home/user/.local/share/godot/keystores/debug.keystore"')
    open(p, 'w').write(s)
    print("  paths written")
PY

echo "== export templates"
if [ ! -f /home/user/.local/share/godot/export_templates/4.7.2.stable/version.txt ]; then
  # 1.2 GB: download to disk (never tmpfs) with resume + retries
  curl -sL --retry 5 --retry-all-errors -C - -o "$PROJECT/../templates.tpz" \
    https://github.com/godotengine/godot/releases/download/4.7.2-stable/Godot_v4.7.2-stable_export_templates.tpz
  mkdir -p /home/user/.local/share/godot/export_templates
  unzip -q -o "$PROJECT/templates.tpz" -d /home/user/.local/share/godot/export_templates/
  mv /home/user/.local/share/godot/export_templates/templates \
     /home/user/.local/share/godot/export_templates/4.7.2.stable
  rm -f "$PROJECT/../templates.tpz"
fi
echo "toolchain ready"
