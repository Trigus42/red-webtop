#!/bin/bash
###############################################################################
# install-autopsy-debian.sh
#
# Reproducible, environment-agnostic installer for the **Autopsy GUI** (4.23.1)
# on **Debian** (as used by the linuxserver.io webtop:debian-kde image), on
# aarch64 or x86_64. Designed to run either:
#   * during a Docker build  (COPY + RUN in Dockerfile.debian), or
#   * by hand inside a running linuxserver.io "webtop" (debian-kde) container.
#
# It only installs SYSTEM-WIDE artifacts (packages, /opt, /usr/local, launcher).
# Per-user setup that lives under the runtime volume /config (desktop menu entry,
# default ingest-module selection) is intentionally NOT done here — in the Docker
# image that is seeded at container start by the s6 init service
# (/etc/s6-overlay/s6-rc.d/init-autopsy-config). If you run this script by hand
# and want those too, pass --seed-config.
#
# ---------------------------------------------------------------------------
# WHY THIS SCRIPT LOOKS THE WAY IT DOES (the three hard constraints)
#
#   1. SLEUTHKIT VERSION == AUTOPSY'S EXPECTED VERSION
#      Autopsy 4.23.1's unix_setup.sh hard-codes TSK_VERSION=4.15.0. Distro
#      sleuthkit packages rarely match exactly AND ship no Java bindings jar, and
#      Autopsy's bundled sleuthkit-4.15.0.jar loads its native lib ONLY from inside
#      the jar at  NATIVELIBS/<os.arch>/linux/libtsk_jni.so  with NO
#      System.loadLibrary fallback (upstream publishes no Linux .so at all). So we
#      build libtsk_jni.so from TSK 4.15.0 source (--enable-java) and inject it into
#      the jar at that exact path.
#
#   2. JAVA 17
#      Autopsy 4.x targets JDK/JRE 17. We install openjdk-17-jdk (newer JDKs are not
#      guaranteed to work with the bundled NetBeans platform).
#
#   3. JAVAFX MISSING FROM THE DEBIAN JDK
#      Autopsy's launcher passes --add-modules javafx.*. The Debian openjdk-17 has
#      no JavaFX, so we install the Gluon OpenJFX 17 SDK for this arch and wire it
#      onto the module path in etc/autopsy.conf.
#
# NOTE ON INGEST MODULES: aLEAPP, iLEAPP, YARA (all coded "requires windows"),
# Embedded File Extractor (7-Zip-JBinding: no ARM native) and Picture Analyzer
# (OpenCV 2.4.13: no ARM native) cannot run on aarch64 Linux and abort ingest if
# enabled. The image ships a default ingest profile with those deselected.
###############################################################################
set -euo pipefail

# ---- versions / sources (override via env at build time if needed) ----------
AUTOPSY_VER="${AUTOPSY_VER:-4.23.1}"
TSK_VER="${TSK_VER:-4.15.0}"
SEED_CONFIG=0
[ "${1:-}" = "--seed-config" ] && SEED_CONFIG=1

# ---- architecture detection --------------------------------------------------
# The sleuthkit jar's loader (LibraryUtils) looks up the native lib inside the jar
# at NATIVELIBS/<java os.arch>/linux/libtsk_jni.so. os.arch is "aarch64" on ARM64
# and "amd64" on x86_64. Detect it so this script works on either arch, and pick
# the matching Gluon OpenJFX SDK + the Debian JDK path (which embeds the arch).
DEB_ARCH="$(dpkg --print-architecture)"     # arm64 | amd64
case "$DEB_ARCH" in
    arm64) JAVA_ARCH="aarch64"; JFX_ARCH="aarch64" ;;
    amd64) JAVA_ARCH="amd64";   JFX_ARCH="x64" ;;
    *) echo "Unsupported dpkg arch: $DEB_ARCH" >&2; exit 1 ;;
esac
JFX_URL="${JFX_URL:-https://download2.gluonhq.com/openjfx/17/openjfx-17_linux-${JFX_ARCH}_bin-sdk.zip}"
JAVA_HOME="${JAVA_HOME:-/usr/lib/jvm/java-17-openjdk-${DEB_ARCH}}"

export DEBIAN_FRONTEND=noninteractive
export JAVA_HOME PATH="$JAVA_HOME/bin:$PATH"
BUILD=/tmp/autopsy-build
mkdir -p "$BUILD"

echo "==> [1/8] apt: JDK17, sleuthkit build deps, forensics runtime, build tools"
apt-get update

# The webtop Debian base is slimmed and omits the man-page tree; the openjdk
# postinst calls update-alternatives for java.1.gz and dies on the missing dir
# ("No such file or directory"). Recreate the man dirs so package installs succeed.
mkdir -p /usr/share/man/man1 /usr/share/man/man2

apt-get install -y --no-install-recommends \
    sleuthkit libtsk-dev \
    testdisk libewf-dev afflib-tools \
    dosfstools mtools \
    build-essential autoconf automake libtool ant ant-optional junit4 \
    zlib1g-dev libsqlite3-dev \
    curl unzip ca-certificates file

echo "==> [1b] Install OpenJDK 17 (Autopsy 4.x requires exactly 17)"
# Debian trixie (13) dropped openjdk-17 (default is 21). Try the base repos first;
# if 17 isn't there, add the bookworm archive (pinned low) just for the JDK.
if apt-get install -y --no-install-recommends openjdk-17-jdk-headless openjdk-17-jdk; then
    echo "    openjdk-17 from base repos"
else
    echo "    openjdk-17 not in base; adding bookworm archive for the JDK only"
    echo "deb http://deb.debian.org/debian bookworm main" \
        > /etc/apt/sources.list.d/bookworm-jdk.list
    cat > /etc/apt/preferences.d/bookworm-jdk.pref <<'PIN'
Package: *
Pin: release n=bookworm
Pin-Priority: 100
PIN
    apt-get update
    apt-get install -y --no-install-recommends -t bookworm openjdk-17-jdk-headless openjdk-17-jdk
fi

echo "==> [2/8] Build The Sleuth Kit ${TSK_VER} Java bindings (libtsk_jni.so + jar)"
cd "$BUILD"
[ -f "sleuthkit-${TSK_VER}.tar.gz" ] || \
    curl -fSL -o "sleuthkit-${TSK_VER}.tar.gz" \
    "https://github.com/sleuthkit/sleuthkit/releases/download/sleuthkit-${TSK_VER}/sleuthkit-${TSK_VER}.tar.gz"
rm -rf "sleuthkit-${TSK_VER}"
tar xzf "sleuthkit-${TSK_VER}.tar.gz"
cd "sleuthkit-${TSK_VER}"
TSK_SRC="$PWD"          # absolute path to the TSK source tree (used again in step 6)
./configure --prefix=/usr/local --enable-java >/dev/null
make -j"$(nproc)"          # builds core libtsk + libtsk_jni + the bindings jar
make install               # installs core libtsk to /usr/local

echo "==> [3/8] Install libtsk_jni.so system-wide and register with ldconfig"
install -m755 bindings/java/jni/.libs/libtsk_jni.so.0.0.0 /usr/local/lib/libtsk_jni.so.0.0.0
ln -sf libtsk_jni.so.0.0.0 /usr/local/lib/libtsk_jni.so.0
ln -sf libtsk_jni.so.0.0.0 /usr/local/lib/libtsk_jni.so
echo "/usr/local/lib" > /etc/ld.so.conf.d/local.conf
ldconfig

echo "==> [4/8] Publish built sleuthkit-${TSK_VER}.jar to /usr/local/share/java"
mkdir -p /usr/local/share/java
install -m644 "bindings/java/dist/sleuthkit-${TSK_VER}.jar" \
    "/usr/local/share/java/sleuthkit-${TSK_VER}.jar"

echo "==> [5/8] Download & extract Autopsy ${AUTOPSY_VER} to /opt"
cd "$BUILD"
[ -f "autopsy-${AUTOPSY_VER}.zip" ] || \
    curl -fSL -o "autopsy-${AUTOPSY_VER}.zip" \
    "https://github.com/sleuthkit/autopsy/releases/download/autopsy-${AUTOPSY_VER}/autopsy-${AUTOPSY_VER}.zip"
rm -rf "/opt/autopsy-${AUTOPSY_VER}"
unzip -q -o "autopsy-${AUTOPSY_VER}.zip" -d /opt

echo "==> [6/8] Inject ${JAVA_ARCH} libtsk_jni.so into both sleuthkit jars (jar-internal loader path)"
WORK="$BUILD/tskinject"
rm -rf "$WORK"; mkdir -p "$WORK/NATIVELIBS/${JAVA_ARCH}/linux"
# Use the absolute source path (cwd changed in step 5). Fall back to the copy
# already installed under /usr/local/lib in step 3 if the build tree is gone.
if [ -f "$TSK_SRC/bindings/java/jni/.libs/libtsk_jni.so.0.0.0" ]; then
    cp "$TSK_SRC/bindings/java/jni/.libs/libtsk_jni.so.0.0.0" \
       "$WORK/NATIVELIBS/${JAVA_ARCH}/linux/libtsk_jni.so"
else
    cp /usr/local/lib/libtsk_jni.so.0.0.0 \
       "$WORK/NATIVELIBS/${JAVA_ARCH}/linux/libtsk_jni.so"
fi
strip "$WORK/NATIVELIBS/${JAVA_ARCH}/linux/libtsk_jni.so" || true
( cd "$WORK"
  for JAR in "/usr/local/share/java/sleuthkit-${TSK_VER}.jar" \
             "/opt/autopsy-${AUTOPSY_VER}/autopsy/modules/ext/sleuthkit-${TSK_VER}.jar"; do
      jar uf "$JAR" NATIVELIBS/${JAVA_ARCH}/linux/libtsk_jni.so
  done )

echo "==> [7/8] Install JavaFX 17, run unix_setup.sh, wire JavaFX into autopsy.conf"
cd "$BUILD"
[ -f openjfx17.zip ] || curl -fSL -o openjfx17.zip "$JFX_URL"
rm -rf /opt/javafx-sdk-17
unzip -q -o openjfx17.zip -d /opt
cd "/opt/autopsy-${AUTOPSY_VER}"
bash unix_setup.sh -j "$JAVA_HOME" || true     # copies the sleuthkit jar into place
if ! grep -q "javafx-sdk-17" etc/autopsy.conf; then
  cp etc/autopsy.conf etc/autopsy.conf.bak
  python3 - <<'PY'
p="etc/autopsy.conf"; s=open(p).read()
ins=("-J--module-path=/opt/javafx-sdk-17/lib "
     "-J--add-modules=javafx.base,javafx.controls,javafx.graphics,"
     "javafx.swing,javafx.media,javafx.fxml,javafx.web ")
open(p,"w").write(s.replace("--branding autopsy ","--branding autopsy "+ins,1))
PY
fi

echo "==> [8/8] Install the /usr/local/bin/autopsy launcher"
cat > /usr/local/bin/autopsy <<LAUNCH
#!/bin/bash
# Autopsy launcher for the webtop KDE desktop (Wayland + XWayland).
export JAVA_HOME=${JAVA_HOME}
# The KDE session runs on X display :0 (XWayland). Force it if the :0 socket exists
# so a stale DISPLAY (e.g. :1) inherited from 'docker exec' cannot break startup.
if [ -S /tmp/.X11-unix/X0 ]; then
    export DISPLAY=:0
elif [ -z "\$DISPLAY" ]; then
    export DISPLAY=:0
fi
[ -z "\$XDG_RUNTIME_DIR" ] && export XDG_RUNTIME_DIR=/config/.XDG
exec /opt/autopsy-${AUTOPSY_VER}/bin/autopsy "\$@"
LAUNCH
chmod +x /usr/local/bin/autopsy

# A stable, version-independent symlink so scripts/desktop entries don't hard-code the version.
ln -sfn "/opt/autopsy-${AUTOPSY_VER}" /opt/autopsy

echo "==> Verifying the install (fail the build if anything critical is missing)"
FAIL=0
check() { if ! eval "$2"; then echo "   MISSING: $1"; FAIL=1; else echo "   ok: $1"; fi; }
check "Autopsy dir"          "[ -d /opt/autopsy-${AUTOPSY_VER} ]"
check "Autopsy launcher"     "[ -x /usr/local/bin/autopsy ]"
check "libtsk_jni.so"        "[ -e /usr/local/lib/libtsk_jni.so ]"
check "sleuthkit jar"        "[ -f /usr/local/share/java/sleuthkit-${TSK_VER}.jar ]"
check "JavaFX SDK"           "[ -d /opt/javafx-sdk-17/lib ]"
check "JavaFX wired in conf" "grep -q javafx-sdk-17 /opt/autopsy-${AUTOPSY_VER}/etc/autopsy.conf"
check "jni injected in jar"  "unzip -l /opt/autopsy-${AUTOPSY_VER}/autopsy/modules/ext/sleuthkit-${TSK_VER}.jar | grep -q NATIVELIBS/${JAVA_ARCH}/linux/libtsk_jni.so"
if [ "$FAIL" != "0" ]; then
    echo "ERROR: install verification failed — see MISSING items above." >&2
    exit 1
fi
echo "   all critical artifacts present."

# Clean the build tree to keep the image small (skip if running by hand).
rm -rf "$BUILD"

# --- optional: seed per-user /config bits when run by hand (not during build) ---
if [ "$SEED_CONFIG" = "1" ]; then
  echo "==> --seed-config: installing desktop entry + default ingest profile into /config"
  /etc/s6-overlay/s6-rc.d/init-autopsy-config/run 2>/dev/null || \
    echo "   (seed script not found; only meaningful inside the built image)"
fi

echo
echo "DONE. System install complete (Debian, ${DEB_ARCH})."
echo "  Launcher : /usr/local/bin/autopsy   (also /opt/autopsy -> /opt/autopsy-${AUTOPSY_VER})"
echo "  In the Docker image, the KDE menu entry and default ingest profile are"
echo "  seeded into /config at container start by the init-autopsy-config service."
