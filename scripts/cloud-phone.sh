#!/usr/bin/env bash
#
# cloud-phone.sh - boot a visual, touch-enabled Android "cloud phone" on a
# GitHub Actions runner, stream it with scrcpy (H.264) via ws-scrcpy, give it
# root (optional), restore/back up user + selected system apps (encrypted), and
# capture crashes.
#
# Everything runs in ONE process tree: GitHub Actions kills background processes
# when a step ends, so the emulator/server/tunnel live here and the script sleeps.
#
set -euo pipefail

API_LEVEL="${API_LEVEL:-30}"          # Android 11: best emulator performance
ARCH="${ARCH:-x86_64}"
TARGET="${TARGET:-google_apis}"       # Google APIs, no Play Store: lighter than playstore
DURATION_MIN="${DURATION_MIN:-300}"
DEVICE="${DEVICE:-pixel_2}"
AVD_NAME="cloudphone"
MAX_SIZE="${MAX_SIZE:-540}"           # scrcpy downscale (lower = smoother)
RESOLUTION="${RESOLUTION:-540x960}"   # device screen: fewer pixels = much smoother
RAM_MB="${RAM_MB:-4096}"              # emulator RAM in MB (the runner has 16 GB)
CORES="${CORES:-4}"                   # emulator CPU cores (the runner has 4 vCPU)
STORAGE="${STORAGE:-10G}"             # /data (internal storage) size
RESTORE="${RESTORE:-1}"               # pull the newest backup back on boot?
# System apps to preserve alongside user apps. pm path returns the ACTIVE apk,
# so an updated system app yields the update, not the stale /system copy.
SYSTEM_APPS="${SYSTEM_APPS:-com.android.vending com.android.chrome}"
WS_PORT="${WS_PORT:-8000}"
ENABLE_MAGISK="${ENABLE_MAGISK:-0}"   # root is optional, off by default
MAGISK_VER="${MAGISK_VER:-25.2}"      # < 26 so rootAVD can patch non-interactively
BACKUP_PASSWORD="${BACKUP_PASSWORD:-}"
BACKUP_INTERVAL_MIN="${BACKUP_INTERVAL_MIN:-15}"
BACKUP_MAX_MB="${BACKUP_MAX_MB:-90}"   # git rejects files over 100 MB - stay under it
# Off-site destination for backups too big for a git branch. Optional: when
# set, the full backup (including /sdcard) is uploaded there and the 'backups'
# branch carries only a small pointer to it.
PIXELDRAIN_API_KEY="${PIXELDRAIN_API_KEY:-}"
ARM_TRANSLATION="${ARM_TRANSLATION:-0}"
NTFY_TOPIC="${NTFY_TOPIC:-}"
NTFY_SERVER="${NTFY_SERVER:-https://ntfy.sh}"
NOTIFY_INTERVAL_MIN="${NOTIFY_INTERVAL_MIN:-30}"
RESTART_EVERY_MIN="${RESTART_EVERY_MIN:-0}"
CRASH_LOG="/tmp/cloudphone-crashes.log"   # app crashes captured during the session
CRASH_SEEN=0

# ARM-only apps need the API 30 image, which is the one that ships Google's
# libndk native bridge. So requesting ARM translation pins the API level.
if [ "${ARM_TRANSLATION}" = "1" ] && [ "${API_LEVEL}" != "30" ]; then
  echo "NOTE: ARM translation needs the API 30 image - overriding API level ${API_LEVEL} -> 30"
  API_LEVEL=30
fi

# Derive the screen density from the width so the UI scales sanely
# (540->240, 720->320, 1080->480).
SCREEN_W="${RESOLUTION%x*}"
SCREEN_H="${RESOLUTION#*x}"
DENSITY="${DENSITY:-$(( SCREEN_W * 100 / 225 ))}"

export ANDROID_HOME="$HOME/android-sdk"
export ANDROID_SDK_ROOT="${ANDROID_HOME}"
export PATH="${ANDROID_HOME}/cmdline-tools/latest/bin:${ANDROID_HOME}/platform-tools:${ANDROID_HOME}/emulator:${PATH}"
export ANDROID_USER_HOME="$HOME/.android"
export ANDROID_AVD_HOME="$HOME/.android/avd"
mkdir -p "${ANDROID_USER_HOME}" "${ANDROID_AVD_HOME}"

log() { echo -e "\n=== $* ==="; }

# ntfy notification. No-op unless NTFY_TOPIC is set.
# $1 title, $2 message, $3 priority (min|low|default|high|max), $4 tags
notify() {
  [ -n "${NTFY_TOPIC}" ] || return 0
  curl -s --max-time 10 \
    -H "Title: ${1}" \
    -H "Priority: ${3:-default}" \
    -H "Tags: ${4:-robot}" \
    -d "${2}" "${NTFY_SERVER}/${NTFY_TOPIC}" >/dev/null 2>&1 || true
}

start_emulator() {
  emulator -avd "${AVD_NAME}" \
    -no-window -no-audio -no-boot-anim -no-snapshot -no-metrics \
    -gpu swiftshader_indirect \
    -memory "${RAM_MB}" -cores "${CORES}" \
    -camera-back none -camera-front none \
    -netdelay none -netspeed full &
  EMU_PID=$!
}

wait_boot() {
  adb start-server >/dev/null 2>&1 || true
  timeout 600 adb wait-for-device || { echo "No emulator device appeared within 10 minutes."; return 1; }
  timeout 900 bash -c 'while [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d "\r\n")" != "1" ]; do sleep 5; done' \
    || { echo "Emulator failed to finish booting in time"; return 1; }
  return 0
}

is_root() {
  [ "$(adb shell id -u 2>/dev/null | tr -d '\r')" = "0" ]
}

# ---- crash capture -------------------------------------------------------
# Stream the Android crash buffer to a file so nothing is missed, then report
# any new crash (Java exception, native signal, ANR) as it happens.
start_crash_watcher() {
  adb logcat -b crash -c >/dev/null 2>&1 || true
  : > "${CRASH_LOG}"
  adb logcat -b crash -v threadtime >> "${CRASH_LOG}" 2>&1 &
  LOGCAT_PID=$!
}

check_crashes() {
  [ -f "${CRASH_LOG}" ] || return 0
  local CUR NEW APP REASON
  CUR=$(wc -c < "${CRASH_LOG}" 2>/dev/null || echo 0)
  [ "${CUR}" -gt "${CRASH_SEEN}" ] || return 0
  NEW="$(tail -c +$(( CRASH_SEEN + 1 )) "${CRASH_LOG}" 2>/dev/null || true)"
  CRASH_SEEN="${CUR}"
  [ -n "${NEW}" ] || return 0
  APP="$(printf '%s' "${NEW}" | grep -m1 -oE 'Process: [^,]+' || true)"
  REASON="$(printf '%s' "${NEW}" | grep -m1 -E 'FATAL EXCEPTION|Fatal signal|SIGSEGV|SIGABRT|Caused by|Exception|Error' || true)"
  echo "--- crash captured ---"
  printf '%s\n' "${NEW}" | tail -30
  notify "Cloud Phone: APP CRASHED" "${APP:-A process crashed}
${REASON:-see log}

$(printf '%s' "${NEW}" | tail -12)" high "boom"
}

# ---------------------------------------------------------------------------
notify "Cloud Phone: starting" "Job started. Provisioning Android ${API_LEVEL} (${TARGET})." low "hourglass"
log "Runner resources"
echo "vCPU: $(nproc)"
free -m | awk 'NR==2{print "RAM: total "$2" MB, available "$7" MB"}'
log "Freeing disk space"
sudo rm -rf /usr/local/lib/android /usr/share/dotnet /opt/ghc \
            /opt/hostedtoolcache/CodeQL /usr/local/share/boost 2>/dev/null || true
df -h / | tail -1

# ---------------------------------------------------------------------------
log "Installing Android SDK (cmdline-tools, emulator, system image)"
mkdir -p "${ANDROID_HOME}/cmdline-tools"
if [ ! -x "${ANDROID_HOME}/cmdline-tools/latest/bin/sdkmanager" ]; then
  curl -sSLo /tmp/cmdline-tools.zip \
    "https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip"
  rm -rf /tmp/cmdline-tools && mkdir -p /tmp/cmdline-tools
  unzip -q /tmp/cmdline-tools.zip -d /tmp/cmdline-tools
  mv /tmp/cmdline-tools/cmdline-tools "${ANDROID_HOME}/cmdline-tools/latest"
fi
yes | sdkmanager --licenses >/dev/null 2>&1 || true
sdkmanager --install "platform-tools" "emulator" "platforms;android-${API_LEVEL}" >/dev/null

IMAGE="system-images;android-${API_LEVEL};${TARGET};${ARCH}"
if ! sdkmanager --install "${IMAGE}" >/dev/null 2>&1; then
  echo "System image '${IMAGE}' is not available - falling back to google_apis."
  TARGET="google_apis"
  IMAGE="system-images;android-${API_LEVEL};${TARGET};${ARCH}"
  sdkmanager --install "${IMAGE}" >/dev/null
fi

# ---------------------------------------------------------------------------
log "Creating AVD"
echo "no" | avdmanager create avd \
  -n "${AVD_NAME}" -k "${IMAGE}" --device "${DEVICE}" --force

AVD_INI="${ANDROID_AVD_HOME}/${AVD_NAME}.avd/config.ini"
if [ -f "${AVD_INI}" ]; then
  sed -i '/^hw\.lcd\.width=/d; /^hw\.lcd\.height=/d; /^hw\.lcd\.density=/d' "${AVD_INI}"
  sed -i '/^disk\.dataPartition\.size=/d; /^disk\.cachePartition\.size=/d; /^sdcard\.size=/d' "${AVD_INI}"
  printf 'hw.lcd.width=%s\nhw.lcd.height=%s\nhw.lcd.density=%s\n' \
    "${SCREEN_W}" "${SCREEN_H}" "${DENSITY}" >> "${AVD_INI}"
  # Internal storage. The stock AVD gives /data only ~1-2 GB, which fills up
  # on the first app install. Set it before first boot so the partition is
  # created at this size (no factory reset needed on a fresh AVD).
  printf 'disk.dataPartition.size=%s\n' "${STORAGE}" >> "${AVD_INI}"
  printf 'disk.cachePartition.size=512M\n' >> "${AVD_INI}"
  echo "Configured /data = ${STORAGE}"
fi

echo "AVDs seen by emulator:"; emulator -list-avds || true
if ! emulator -list-avds | grep -qx "${AVD_NAME}"; then
  echo "ERROR: AVD '${AVD_NAME}' was not registered. Aborting."
  notify "Cloud Phone: FAILED" "AVD was not registered." high "x"
  exit 1
fi

# ---------------------------------------------------------------------------
log "Booting the Android emulator (headless)"
start_emulator
sleep 5
if ! kill -0 "${EMU_PID}" 2>/dev/null; then
  echo "ERROR: the emulator process exited immediately after launch."
  notify "Cloud Phone: FAILED" "Emulator exited immediately after launch." high "x"
  exit 1
fi
wait_boot || exit 1
echo "Emulator booted."

# Software rendering is the bottleneck, so turn off the animation overhead.
log "Tuning the device for smoothness"
for s in window_animation_scale transition_animation_scale animator_duration_scale; do
  adb shell settings put global "$s" 0 >/dev/null 2>&1 || true
done
echo "  animations disabled; screen ${SCREEN_W}x${SCREEN_H} @ ${DENSITY}dpi; ${RAM_MB} MB RAM, ${CORES} cores"
log "Storage available inside Android"
adb shell df -h /data 2>/dev/null | tail -1 || true
adb shell df -h /sdcard 2>/dev/null | tail -1 || true
notify "Cloud Phone: VM started" "Android ${API_LEVEL} (${TARGET}) emulator booted.
Screen ${SCREEN_W}x${SCREEN_H} @${DENSITY}dpi, ${RAM_MB} MB RAM, ${CORES} cores, /data ${STORAGE}." default "phone"

log "Device ABI support (decides whether ARM-only APKs can install)"
for p in ro.product.cpu.abilist ro.product.cpu.abilist64 ro.product.cpu.abilist32 \
         ro.enable.native.bridge.exec ro.dalvik.vm.native.bridge; do
  echo "  ${p} = $(adb shell getprop ${p} 2>/dev/null | tr -d '\r')"
done

# ---------------------------------------------------------------------------
log "Root: 'adb root' (works on google_apis/default, refused on playstore images)"
adb root >/dev/null 2>&1 || true
sleep 3
ROOT_OK=0
if is_root; then ROOT_OK=1; fi
SU_OK=0
echo "adb root: ${ROOT_OK}"

try_su() { adb shell su -c id 2>/dev/null | grep -q 'uid=0'; }

if [ "${ENABLE_MAGISK}" = "1" ]; then
  log "Root: installing Magisk via rootAVD (best effort, Magisk ${MAGISK_VER})"
  set +e
  if [ ! -d "$HOME/rootAVD" ]; then
    git clone --depth 1 https://github.com/newbit1/rootAVD.git "$HOME/rootAVD"
  fi
  curl -sSL -o "$HOME/rootAVD/Magisk.zip" \
    "https://github.com/topjohnwu/Magisk/releases/download/v${MAGISK_VER}/Magisk-v${MAGISK_VER}.apk"
  RAMDISK_REL="system-images/android-${API_LEVEL}/${TARGET}/${ARCH}/ramdisk.img"
  ( cd "$HOME/rootAVD" && chmod +x rootAVD.sh && ./rootAVD.sh "${RAMDISK_REL}" ) 2>&1 | tail -80
  set -e
  # rootAVD shuts the AVD down. Wait for the old emulator to fully exit first,
  # or the new one refuses to start ("multiple emulators with the same AVD").
  adb emu kill >/dev/null 2>&1 || true
  for _ in $(seq 1 30); do
    kill -0 "${EMU_PID}" 2>/dev/null || break
    sleep 2
  done
  pkill -f "qemu-system" >/dev/null 2>&1 || true
  sleep 3
  adb kill-server >/dev/null 2>&1 || true
  sleep 2
  start_emulator
  sleep 5
  if wait_boot; then
    adb root >/dev/null 2>&1 || true
    sleep 3
    if is_root; then ROOT_OK=1; fi
    for _ in 1 2 3 4 5; do
      if try_su; then SU_OK=1; break; fi
      adb shell input keyevent 61 >/dev/null 2>&1 || true
      adb shell input keyevent 61 >/dev/null 2>&1 || true
      adb shell input keyevent 66 >/dev/null 2>&1 || true
      sleep 3
    done
  else
    echo "Reboot after Magisk failed; continuing with what we have."
  fi
  echo "root after Magisk step: adb=${ROOT_OK} su=${SU_OK}"
  notify "Cloud Phone: root" "Magisk step done - adb=${ROOT_OK} su=${SU_OK}" low "key"
fi

# ---------------------------------------------------------------------------
# ARM translation. Finding from a real run: the API 30 (Android 11)
# google_apis / google_apis_playstore images ALREADY ship Google's libndk
# native bridge and advertise arm64-v8a / armeabi-v7a, so ARM-only APKs install
# with no extra work. (Newer images, e.g. API 33, do not.) Enabling this
# therefore just means "use API 30" - no Magisk module is required.
if [ "${ARM_TRANSLATION}" = "1" ]; then
  log "ARM translation: using the image's built-in libndk native bridge"
  echo "  native bridge : $(adb shell getprop ro.dalvik.vm.native.bridge 2>/dev/null | tr -d '\r')"
  echo "  abilist       : $(adb shell getprop ro.product.cpu.abilist 2>/dev/null | tr -d '\r')"
  if adb shell getprop ro.product.cpu.abilist 2>/dev/null | grep -q 'arm64-v8a'; then
    echo "  -> ARM ABIs advertised: arm64-only APKs should install and run."
  else
    echo "  -> No ARM ABI advertised; ARM-only APKs will NOT install on this image."
  fi
fi

# ---------------------------------------------------------------------------
log "Starting the crash watcher (captures app crashes as they happen)"
start_crash_watcher
echo "Crash watcher running - crashes will be reported and bundled with the backup."

# ---- pixeldrain ----------------------------------------------------------
# Auth uses the API key in the HTTP Basic *password* field; the username is
# ignored. Upload is a raw PUT to /api/file/<name> and returns {"id": ...}.
pixeldrain_upload() {
  local file="$1" resp id
  resp="$(curl -sS --max-time 1800 -T "${file}" -u ":${PIXELDRAIN_API_KEY}" \
            "https://pixeldrain.com/api/file/$(basename "${file}")" 2>/dev/null || true)"
  id="$(printf '%s' "${resp}" | jq -r '.id // empty' 2>/dev/null || true)"
  if printf '%s' "${resp}" | jq -e '.success == true' >/dev/null 2>&1 && [ -n "${id}" ]; then
    printf '%s' "${id}"
    return 0
  fi
  echo "  Pixeldrain upload failed: ${resp}" >&2
  return 1
}

pixeldrain_delete() {
  [ -n "${1:-}" ] || return 0
  curl -sS --max-time 60 -X DELETE -u ":${PIXELDRAIN_API_KEY}" \
    "https://pixeldrain.com/api/file/$1" >/dev/null 2>&1 || true
}

# Keep only a tiny pointer on the 'backups' branch so restore can find the blob.
write_pointer() {
  local id="$1" size="$2" name="$3" stamp="$4"
  (
    cd "${GITHUB_WORKSPACE:-$PWD}"
    git config user.email "cloud-phone-bot@users.noreply.github.com"
    git config user.name "cloud-phone-bot"
    git checkout --orphan "ptr-${stamp}" >/dev/null 2>&1 || true
    git rm -rf --cached . >/dev/null 2>&1 || true
    mkdir -p backups
    printf 'pixeldrain_id=%s\nname=%s\nsize=%s\ntimestamp=%s\n' \
      "${id}" "${name}" "${size}" "${stamp}" > backups/latest.txt
    git add -f backups/latest.txt
    git commit -m "Backup pointer ${stamp}" >/dev/null 2>&1 || true
    git push -f origin "HEAD:refs/heads/backups"
  ) >/tmp/push.log 2>&1
}

# ---- restore -------------------------------------------------------------
# Pull the newest backup (Pixeldrain via the pointer, or a blob on the branch)
# and put the apps and their data back onto this fresh emulator.
restore_latest_backup() {
  [ "${RESTORE}" = "1" ] || { echo "Restore disabled by input."; return 0; }
  [ -n "${BACKUP_PASSWORD}" ] || { echo "No BACKUP_PASSWORD - nothing to restore."; return 0; }
  [ -n "${GITHUB_REPOSITORY:-}" ] || { echo "No GITHUB_REPOSITORY - skipping restore."; return 0; }

  local API LIST LATEST WORK ENC RESTORED FAILED UG PTR PD_ID
  ENC="/tmp/restore.enc"

  # Preferred: a Pixeldrain pointer on the branch (handles big backups).
  PTR="$(curl -sSL --max-time 30 \
          "https://raw.githubusercontent.com/${GITHUB_REPOSITORY}/backups/backups/latest.txt" 2>/dev/null || true)"
  PD_ID="$(printf '%s' "${PTR}" | sed -n 's/^pixeldrain_id=//p' | tr -d '\r')"
  if [ -n "${PD_ID}" ]; then
    echo "Fetching ${PD_ID} from Pixeldrain"
    if ! curl -sSL --max-time 1800 -u ":${PIXELDRAIN_API_KEY:-}" -o "${ENC}" \
          "https://pixeldrain.com/api/file/${PD_ID}"; then
      echo "Pixeldrain download failed - trying the branch instead."
      PD_ID=""
    fi
  fi

  if [ -z "${PD_ID}" ]; then
    API="https://api.github.com/repos/${GITHUB_REPOSITORY}/contents/backups?ref=backups"
    LIST="$(curl -sSL --max-time 30 -H "Authorization: Bearer ${GITHUB_TOKEN:-}" \
              -H "Accept: application/vnd.github+json" "${API}" 2>/dev/null || true)"
    LATEST="$(printf '%s' "${LIST}" | jq -r '.[]? | select(.name|endswith(".tar.gz.enc")) | .name' 2>/dev/null | sort | tail -1)"
    if [ -z "${LATEST}" ] || [ "${LATEST}" = "null" ]; then
      echo "No backup found yet - starting fresh."
      return 0
    fi
    echo "Restoring from ${LATEST}"
    if ! curl -sSL --max-time 300 -o "${ENC}" \
          "https://raw.githubusercontent.com/${GITHUB_REPOSITORY}/backups/backups/${LATEST}"; then
      echo "Backup download failed - continuing without restore."
      return 0
    fi
  fi

  if [ ! -s "${ENC}" ]; then
    echo "Backup download produced no data - continuing without restore."
    return 0
  fi

  WORK="$(mktemp -d)"
  if ! openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 \
        -pass env:BACKUP_PASSWORD -in "${ENC}" | tar -xzf - -C "${WORK}" 2>/dev/null; then
    echo "Decrypt/extract failed - is BACKUP_PASSWORD the same as when it was made?"
    notify "Cloud Phone: restore failed" "Could not decrypt the backup. Wrong BACKUP_PASSWORD?" high "x"
    rm -rf "${WORK}" "${ENC}"
    return 0
  fi
  rm -f "${ENC}"

  RESTORED=0; FAILED=0
  if [ -d "${WORK}/apps" ]; then
    for d in "${WORK}"/apps/*/; do
      [ -d "${d}" ] || continue
      pkg="$(basename "${d}")"
      echo "  restoring ${pkg}"
      if adb install-multiple -r -d -g "${d}"*.apk >/dev/null 2>&1 \
         || adb install -r -d -g "${d}"*.apk >/dev/null 2>&1; then
        RESTORED=$((RESTORED+1))
      else
        echo "    (apk install failed)"
        FAILED=$((FAILED+1))
      fi
      # Private app data - only restorable with root.
      if [ -s "${d}data.tar.gz" ]; then
        if [ "${ROOT_OK}" = "1" ] || [ "${SU_OK}" = "1" ]; then
          adb shell am force-stop "${pkg}" >/dev/null 2>&1 || true
          UG="$(adb shell stat -c '%u:%g' /data/user/0/${pkg} 2>/dev/null | tr -d '\r')"
          adb push "${d}data.tar.gz" /data/local/tmp/r.tar.gz >/dev/null 2>&1 || true
          adb shell "tar -xzf /data/local/tmp/r.tar.gz -C /data/user/0" >/dev/null 2>&1 || true
          [ -n "${UG}" ] && adb shell "chown -R ${UG} /data/user/0/${pkg}" >/dev/null 2>&1 || true
          adb shell "restorecon -R /data/user/0/${pkg}" >/dev/null 2>&1 || true
          adb shell "rm -f /data/local/tmp/r.tar.gz" >/dev/null 2>&1 || true
        else
          echo "    (no root - private data not restored)"
        fi
      fi
      # External (shared) app data.
      if [ -s "${d}external.tar.gz" ]; then
        adb push "${d}external.tar.gz" /data/local/tmp/e.tar.gz >/dev/null 2>&1 || true
        adb shell "mkdir -p /sdcard/Android/data/${pkg}" >/dev/null 2>&1 || true
        adb shell "tar -xzf /data/local/tmp/e.tar.gz -C /sdcard/Android/data" >/dev/null 2>&1 || true
        adb shell "rm -f /data/local/tmp/e.tar.gz" >/dev/null 2>&1 || true
      fi
    done
  fi

  # User files from /sdcard.
  if [ -s "${WORK}/sdcard.tar.gz" ]; then
    echo "  restoring /sdcard user files"
    adb push "${WORK}/sdcard.tar.gz" /data/local/tmp/s.tar.gz >/dev/null 2>&1 || true
    adb shell "tar -xzf /data/local/tmp/s.tar.gz -C /sdcard" >/dev/null 2>&1 || true
    adb shell "rm -f /data/local/tmp/s.tar.gz" >/dev/null 2>&1 || true
  fi

  rm -rf "${WORK}"
  echo "Restore done: ${RESTORED} app(s) installed, ${FAILED} failed."
  notify "Cloud Phone: restored" "Restored ${RESTORED} app(s)." default "inbox_tray"
  return 0
}

# Capture one package: its active APK(s), its private data (root only), and
# its external data. Shared by the user-app and extra-system-app passes.
backup_one_app() {
  local pkg="$1" WORK="$2"
  mkdir -p "${WORK}/apps/${pkg}"
  adb shell am force-stop "${pkg}" >/dev/null 2>&1 || true

  adb shell pm path "${pkg}" 2>/dev/null | sed 's/^package://' | tr -d '\r' | while read -r apk; do
    [ -n "${apk}" ] && adb pull "${apk}" "${WORK}/apps/${pkg}/" >/dev/null 2>&1 || true
  done

  if [ "${ROOT_OK}" = "1" ]; then
    adb exec-out "tar -czf - -C /data/user/0 ${pkg} 2>/dev/null" > "${WORK}/apps/${pkg}/data.tar.gz" 2>/dev/null || true
  elif [ "${SU_OK}" = "1" ]; then
    adb exec-out "su -c 'tar -czf - -C /data/user/0 ${pkg}'" > "${WORK}/apps/${pkg}/data.tar.gz" 2>/dev/null || true
  else
    : > "${WORK}/apps/${pkg}/data.tar.gz"
  fi

  adb exec-out "tar -czf - -C /sdcard/Android/data ${pkg} 2>/dev/null" > "${WORK}/apps/${pkg}/external.tar.gz" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
do_backup() {
  [ -n "${BACKUP_PASSWORD}" ] || { echo "No BACKUP_PASSWORD set - skipping backup."; return 0; }
  local WORK OUT BUNDLE STAMP SIZE MAX_BYTES
  WORK="$(mktemp -d)"
  STAMP="$(date -u +%Y%m%d-%H%M%S)"
  echo "Backing up user apps (root=${ROOT_OK}) at ${STAMP}"

  adb shell pm list packages -3 2>/dev/null | sed 's/^package://' | tr -d '\r' > "${WORK}/applist.txt" || true
  echo "User-installed apps: $(wc -l < "${WORK}/applist.txt")"

  while read -r pkg; do
    [ -n "${pkg}" ] || continue
    echo "  - ${pkg}"
    backup_one_app "${pkg}" "${WORK}"
  done < "${WORK}/applist.txt"

  # System apps the user wants preserved across sessions (Play Store, Chrome,
  # ...). Their APKs matter less than their DATA - the Google sign-in and
  # Chrome's bookmarks/history live there.
  for pkg in ${SYSTEM_APPS}; do
    if adb shell pm path "${pkg}" 2>/dev/null | grep -q .; then
      echo "  [system] ${pkg}"
      backup_one_app "${pkg}" "${WORK}"
    fi
  done

  { echo "cloud-phone backup"; echo "timestamp: ${STAMP}"; echo "root: ${ROOT_OK}";
    echo "api-level: ${API_LEVEL}"; echo "target: ${TARGET}"; } > "${WORK}/MANIFEST.txt"
  adb shell pm list packages 2>/dev/null | tr -d '\r' > "${WORK}/packages-all.txt" || true
  [ -f "${CRASH_LOG}" ] && cp "${CRASH_LOG}" "${WORK}/crashes.log" || true

  # User files on /sdcard (Downloads, Pictures, ...). App-private Android/ is
  # handled per-app above.
  adb exec-out "tar -czf - -C /sdcard --exclude=Android . 2>/dev/null" > "${WORK}/sdcard.tar.gz" 2>/dev/null || true

  # Never let an empty session's snapshot overwrite a good one.
  APP_COUNT=$(grep -c . "${WORK}/applist.txt" 2>/dev/null || echo 0)
  SDCARD_BYTES=$(stat -c %s "${WORK}/sdcard.tar.gz" 2>/dev/null || echo 0)
  if [ "${APP_COUNT}" -eq 0 ] && [ "${SDCARD_BYTES}" -lt 10000 ]; then
    echo "Nothing to back up (0 user apps, no user files) - keeping the existing backup."
    rm -rf "${WORK}"
    return 0
  fi
  echo "Backup contents: ${APP_COUNT} user app(s), /sdcard ${SDCARD_BYTES} bytes"

  BUNDLE="/tmp/cloudphone-bundle.tar.gz"
  OUT="/tmp/cloudphone-backup-${STAMP}.tar.gz.enc"
  MAX_BYTES=$(( BACKUP_MAX_MB * 1024 * 1024 ))

  tar -czf "${BUNDLE}" -C "${WORK}" .
  openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt \
    -pass env:BACKUP_PASSWORD -in "${BUNDLE}" -out "${OUT}"
  SIZE=$(stat -c %s "${OUT}" 2>/dev/null || echo 0)
  echo "Encrypted backup: $(du -h "${OUT}" | cut -f1)"

  # ---- publish: Pixeldrain first (no 100 MB file limit) -------------------
  if [ -n "${PIXELDRAIN_API_KEY}" ]; then
    echo "Uploading to Pixeldrain..."
    PD_ID="$(pixeldrain_upload "${OUT}" || true)"
    if [ -n "${PD_ID}" ]; then
      echo "Pixeldrain file id: ${PD_ID}"
      OLD_ID="$(curl -sSL --max-time 30 \
        "https://raw.githubusercontent.com/${GITHUB_REPOSITORY}/backups/backups/latest.txt" 2>/dev/null \
        | sed -n 's/^pixeldrain_id=//p' | tr -d '\r' || true)"
      if write_pointer "${PD_ID}" "${SIZE}" "$(basename "${OUT}")" "${STAMP}"; then
        echo "Pointer pushed to 'backups'."
        if [ -n "${OLD_ID}" ] && [ "${OLD_ID}" != "${PD_ID}" ]; then
          pixeldrain_delete "${OLD_ID}"
          echo "Deleted previous Pixeldrain file ${OLD_ID} (newest only)."
        fi
        notify "Cloud Phone: backup uploaded" "Pixeldrain ${PD_ID} ($(du -h "${OUT}" | cut -f1))." low "floppy_disk"
        rm -f "${OUT}"
        rm -rf "${WORK}" "${BUNDLE}"
        return 0
      fi
      echo "Could not push the pointer - the file is still on Pixeldrain."
    fi
    echo "Pixeldrain path failed - falling back to the git branch."
  fi

  # ---- fallback: the 'backups' branch (git rejects files over 100 MB) -----
  # GitHub hard-rejects any file over 100 MB, so an oversized backup can never
  # be pushed - it just fails silently every interval. Apps and their data are
  # the important part, so drop the /sdcard payload first and retry.
  if [ "${SIZE}" -gt "${MAX_BYTES}" ] && [ -f "${WORK}/sdcard.tar.gz" ]; then
    echo "Backup is $(du -h "${OUT}" | cut -f1) - over the ${BACKUP_MAX_MB} MB git limit; dropping /sdcard files, keeping apps + app data."
    rm -f "${WORK}/sdcard.tar.gz" "${BUNDLE}" "${OUT}"
    tar -czf "${BUNDLE}" -C "${WORK}" .
    openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt \
      -pass env:BACKUP_PASSWORD -in "${BUNDLE}" -out "${OUT}"
    SIZE=$(stat -c %s "${OUT}" 2>/dev/null || echo 0)
  fi
  if [ "${SIZE}" -gt "${MAX_BYTES}" ]; then
    echo "Backup is still $(du -h "${OUT}" | cut -f1) - too large to push to git. Keeping the existing backup."
    rm -rf "${WORK}" "${BUNDLE}" "${OUT}"
    return 0
  fi
  rm -rf "${WORK}" "${BUNDLE}"

  # Safety net: never replace an existing backup with one less than half its
  # size. That is exactly how a bare session used to wipe a good snapshot.
  NEW_BYTES=$(stat -c %s "${OUT}" 2>/dev/null || echo 0)
  OLD_BYTES=0
  if [ -n "${GITHUB_REPOSITORY:-}" ]; then
    OLD_BYTES=$(curl -sSL --max-time 30 -H "Authorization: Bearer ${GITHUB_TOKEN:-}" \
      "https://api.github.com/repos/${GITHUB_REPOSITORY}/contents/backups?ref=backups" 2>/dev/null \
      | jq -r '.[]?|.size' 2>/dev/null | sort -n | tail -1)
    [ -n "${OLD_BYTES}" ] || OLD_BYTES=0
  fi
  if [ "${OLD_BYTES}" -gt 0 ] && [ "${NEW_BYTES}" -lt $(( OLD_BYTES / 2 )) ]; then
    echo "New backup (${NEW_BYTES}B) is under half the existing one (${OLD_BYTES}B) - keeping the existing backup."
    rm -f "${OUT}"
    return 0
  fi

  # Publish ONLY the newest snapshot: build a fresh single-file commit and
  # force-push it to the 'backups' branch, so the branch never accumulates.
  (
    cd "${GITHUB_WORKSPACE:-$PWD}"
    git config user.email "cloud-phone-bot@users.noreply.github.com"
    git config user.name "cloud-phone-bot"
    BR="backup-${STAMP}"
    git checkout --orphan "${BR}" >/dev/null 2>&1 || true
    git rm -rf --cached . >/dev/null 2>&1 || true
    mkdir -p backups
    cp "${OUT}" "backups/$(basename "${OUT}")"
    git add -f "backups/$(basename "${OUT}")"
    git commit -m "Encrypted cloud phone backup ${STAMP} (latest only)" >/dev/null 2>&1 || true
    git push -f origin "HEAD:refs/heads/backups"
  ) >/tmp/push.log 2>&1 && {
    echo "Backup pushed to 'backups' (latest only)."
    notify "Cloud Phone: backup pushed" "Encrypted snapshot pushed to branch 'backups' (newest only)." low "floppy_disk"
  } || { echo "Backup push failed. git said:"; tail -4 /tmp/push.log; }
  rm -f "${OUT}"
  return 0
}

# ---------------------------------------------------------------------------
log "Restoring the newest backup (if any)"
restore_latest_backup

# ---------------------------------------------------------------------------
log "Building ws-scrcpy (H.264 streaming server)"
rm -rf "$HOME/ws-scrcpy"
git clone --depth 1 https://github.com/NetrisTV/ws-scrcpy.git "$HOME/ws-scrcpy"
cd "$HOME/ws-scrcpy"
cat > build.config.override.json <<'JSON'
{
  "INCLUDE_ADB_SHELL": false,
  "SCRCPY_LISTENS_ON_ALL_INTERFACES": false
}
JSON
npm install --ignore-scripts --omit=optional --no-audit --no-fund
npm run dist

log "Starting ws-scrcpy server on port ${WS_PORT}"
node dist/index.js > /tmp/ws-scrcpy.log 2>&1 &
WSS_PID=$!
sleep 8
if ! kill -0 "${WSS_PID}" 2>/dev/null; then
  echo "ws-scrcpy server exited immediately. Log follows:"
  cat /tmp/ws-scrcpy.log
  notify "Cloud Phone: FAILED" "ws-scrcpy server exited immediately." high "x"
  exit 1
fi
curl -s -o /dev/null -w "ws-scrcpy HTTP status: %{http_code}\n" "http://localhost:${WS_PORT}/" || true

# ---------------------------------------------------------------------------
log "Opening a public tunnel (Cloudflare quick tunnel - no account needed)"
curl -sSLo /tmp/cloudflared \
  "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
chmod +x /tmp/cloudflared
/tmp/cloudflared tunnel --url "http://localhost:${WS_PORT}" --no-autoupdate \
  >/tmp/cloudflared.log 2>&1 &

URL=""
for _ in $(seq 1 60); do
  URL="$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' /tmp/cloudflared.log | head -1 || true)"
  [ -n "${URL}" ] && break
  sleep 2
done

if [ -z "${URL}" ]; then
  echo "Could not obtain a tunnel URL. cloudflared log follows:"
  cat /tmp/cloudflared.log
  notify "Cloud Phone: FAILED" "Could not obtain a tunnel URL." high "x"
  exit 1
fi

echo ""
echo "###############################################################"
echo "#                                                             #"
echo "#   YOUR CLOUD PHONE IS LIVE  (scrcpy / H.264)                #"
echo "#                                                             #"
echo "#   Open this in your browser:                                #"
echo "#     ${URL}"
echo "#                                                             #"
echo "#   Then: click your device, and pick 'proxy over adb'.       #"
echo "#   Root: adb=${ROOT_OK} su=${SU_OK}  ARM: ${ARM_TRANSLATION}  Screen: ${RESOLUTION}  #"
echo "#   Backup: $([ -n "${BACKUP_PASSWORD}" ] && echo "on, every ${BACKUP_INTERVAL_MIN} min -> $([ -n "${PIXELDRAIN_API_KEY}" ] && echo Pixeldrain || echo branch 'backups')" || echo "off (no BACKUP_PASSWORD)")#"
echo "#   Stays up for ${DURATION_MIN} minutes.                         #"
echo "#                                                             #"
echo "###############################################################"
echo ""

notify "Cloud Phone is LIVE" "URL: ${URL}
API ${API_LEVEL} / ${TARGET}
Screen: ${RESOLUTION}
Root: adb=${ROOT_OK} su=${SU_OK}
Session: ${DURATION_MIN} min" high "rocket"

# ---------------------------------------------------------------------------
log "Keeping the phone alive for ${DURATION_MIN} minutes"
NOW="$(date +%s)"
END=$(( NOW + DURATION_MIN * 60 ))
NEXT_BACKUP=$(( NOW + 60 ))   # first backup ~1 min in, then every interval
NEXT_NOTIFY=$(( NOW + NOTIFY_INTERVAL_MIN * 60 ))
NEXT_RESTART=$(( NOW + RESTART_EVERY_MIN * 60 ))
while [ "$(date +%s)" -lt "${END}" ]; do
  if ! kill -0 "${EMU_PID}" 2>/dev/null; then
    echo "Emulator process exited - stopping."
    notify "Cloud Phone DIED" "The emulator exited unexpectedly." high "warning"
    break
  fi
  TS="$(date +%s)"
  check_crashes
  if [ -n "${BACKUP_PASSWORD}" ] && [ "${TS}" -ge "${NEXT_BACKUP}" ]; then
    do_backup || echo "Backup attempt failed; will retry next interval."
    NEXT_BACKUP=$(( $(date +%s) + BACKUP_INTERVAL_MIN * 60 ))
  fi
  if [ "${TS}" -ge "${NEXT_NOTIFY}" ]; then
    LEFT=$(( (END - TS) / 60 ))
    UPTIME=$(( (TS - NOW) / 60 ))
    APPS=$(adb shell pm list packages -3 2>/dev/null | wc -l)
    MEM=$(adb shell cat /proc/meminfo 2>/dev/null | awk '/MemAvailable/{print int($2/1024)" MB"}')
    if [ -n "${BACKUP_PASSWORD}" ]; then NB="$(( (NEXT_BACKUP - TS) / 60 )) min"; else NB="n/a"; fi
    notify "Cloud Phone status" "URL: ${URL}
Remaining: ${LEFT} min (of ${DURATION_MIN})
Uptime: ${UPTIME} min
User apps: ${APPS}
Free RAM: ${MEM}
Root: adb=${ROOT_OK} su=${SU_OK}
Next backup in: ${NB}" default "bar_chart"
    NEXT_NOTIFY=$(( TS + NOTIFY_INTERVAL_MIN * 60 ))
  fi
  if [ "${RESTART_EVERY_MIN}" -gt 0 ] && [ "${TS}" -ge "${NEXT_RESTART}" ]; then
    notify "Cloud Phone restarting" "Scheduled emulator reboot now (every ${RESTART_EVERY_MIN} min)." default "arrows_counterclockwise"
    adb reboot >/dev/null 2>&1 || true
    sleep 20
    wait_boot || echo "Scheduled reboot failed."
    start_crash_watcher
    notify "Cloud Phone back up" "Emulator rebooted and back online.
URL: ${URL}" default "white_check_mark"
    NEXT_RESTART=$(( $(date +%s) + RESTART_EVERY_MIN * 60 ))
  fi
  sleep 30
done

if [ -n "${BACKUP_PASSWORD}" ]; then
  log "Final backup"
  do_backup || echo "Final backup failed."
fi

CRASHES=$(grep -c -E 'FATAL EXCEPTION|Fatal signal|ANR in' "${CRASH_LOG}" 2>/dev/null || echo 0)
notify "Cloud Phone ended" "Session finished. Crash entries captured: ${CRASHES}." default "checkered_flag"
echo "Session finished."
