# mi_nobl_magisk

Magisk v30.7 on locked bootloader via two vulnerabilities affecting Qualcomm + MIUI/HyperOS devices.

Made with Claude AI and a lot of fixing on my own

## Vulnerabilities exploited

1. **Qualcomm fastboot `oem set-gpu-preemption`** — allows injecting arbitrary kernel cmdline
   parameters, used here to set `androidboot.selinux=permissive`

2. **`miui.mqsas.IMQSNative` binder service** — MIUI/HyperOS service running
   as root that accepts arbitrary shell command execution. Combined with echo `u:r:su:s0 > /proc/self/attr/current`
   gives full root with correct SELinux context.

## Why Magisk instead of KernelSU

KernelSU requires a `.ko` matched to the exact kernel version. For kernel 6.6.x / Android 16
there are no prebuilt releases (or at least i didn't find them), and building the whole kernel is annoying.
Magisk is purely userspace — no kernel module, works on any kernel version.

## How it works

```
fastboot oem set-gpu-preemption 0 androidboot.selinux=permissive
  └─ kernel boots with SELinux permissive
      └─ service call miui.mqsas.IMQSNative 21 ... runcon u:r:su:s0
          └─ setup: deploy binaries to /data/adb/magisk/
          └─ start: mount tmpfs MAGISKTMP, load sepolicy, start magiskd
```

## Requirements

- MIUI or HyperOS device with vulnerable fastboot interface (Qualcomm)
- MQSas service present on your HyperOS build and device vulnerable
- adb + fastboot on host

## Usage

```bash
# plug in device, then:
chmod +x host_magisk.sh
./host_magisk.sh
```

The script will:
1. Reboot to fastboot
2. Inject permissive SELinux via cmdline
3. Continue boot and wait for Android
4. Push binaries and scripts
5. Run setup via MQSas (deploys to /data/adb/magisk/)
6. Run start via MQSas (mounts tmpfs, starts magiskd)
7. Downloads and installs Magisk Manager APK
8. Provide scripts to auth apps to use root (because magisk prompt might be broken so we directly query the apps into magisk.db and auth them)

## Re-running after reboot

Since this is a temp root you must re-run `host_magisk.sh` every reboot.
The setup stage if magisk has already been deployed previously will be skipped on subsequent boots.

## Porting to other devices

- If MQSas transactions don't respond, enumerate nearby transactions (20, 22, 23...)
- If `echo u:r:su:s0 > /proc/self/attr/current` is blocked, try `runcon u:r:su:s0` or try other contexts
  (MQSas runs as root anyway, just without the ideal context)

## Credits

- Original KernelSU locked-BL hack as inspiration:https://github.com/xunchahaha/mi_nobl_root
- j4nn @ xda for the original Magisk-on-exploit concept (v20.4):https://github.com/j4nn
- polygraphene dirtypipe startup-root script for the 'CANNOT LINK EXECUTABLE "/system/bin/app_process64": library "libnativeloader.so" not found' and boot classpath fixes:https://github.com/polygraphene/DirtyPipe-Android/blob/master/startup-root
