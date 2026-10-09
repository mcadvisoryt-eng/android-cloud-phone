#!/usr/bin/env bash
#
# cloud-phone.sh - boot a visual, touch-enabled Android "cloud phone" on a
# GitHub Actions runner, stream it with scrcpy (H.264) via ws-scrcpy, give it
# root, and periodically back up user apps (encrypted).
#
# Everything runs in ONE process tree: GitHub Actions kills background processes
# when a step ends, so the emulator/server/tunnel live here and the script sleeps.
#
set -euo pipefail

API_LEVEL="${API_LEVEL:-33}"
ARCH="${ARCH:-x86_64}"
TARGET="${TARGET:-google_apis_playstore}"
DURATION_MIN="${DURATION_MIN:-300}"
DEVICE="${DEVICE:-pixel_2}"
AVD_NAME="cloudphone"
MAX_SIZE="${MAX_SIZE:-640}"
WS_PORT="${WS_PORT:-8000}"
ENABLE_MAGISK="${ENABLE_MAGISK:-1}"
MAGISK_VER="${MAGISK_VER:-25.2}"
BACKUP_PASSWORD="${BACKUP_PASSWORD:-}"
BACKUP_INTERVAL_MIN="${BACKUP_INTERVAL_MIN:-15}"
ARM_TRANSLATION="${ARM_TRANSLATION:-0}"

# ARM-only apps need the API 30 image, which is the one that ships Google's
# libndk native bridge. So requesting ARM translation pins the API level.
if [ "${ARM_TRANSLATION}" = "1" ] && [ "${API_LEVEL}" != "30" ]; then
  echo "NOTE: ARM translation needs the API 30 image - overriding API level ${API_LEVEL} -> 30"
  API_LEVEL=30
fi

export ANDROID_HOME="$HOME/android-sdk"
export ANDROID_SDK_ROOT="${ANDROID_HOME}"
export PATH="${ANDROID_HOME}/cmdline-tools/latest/bin:${ANDROID_HOME}/platform-tools:${ANDROID_HOME}/emulator:${PATH}"
export ANDROID_USER_HOME="$HOME/.android"
export ANDROID_AVD_HOME="$HOME/.android/avd"
mkdir -p "${ANDROID_USER_HOME}" "${ANDROID_AVD_HOME}"

log() { echo -e "\n=== $* ==="; }

start_emulator() {
  emulator -avd "${AVD_NAME}" \
    -no-window -no-audio -no-boot-anim -no-snapshot -no-metrics \
    -gpu swiftshader_indirect \
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

# ---------------------------------------------------------------------------
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
  printf 'hw.lcd.width=720\nhw.lcd.height=1280\nhw.lcd.density=320\n' >> "${AVD_INI}"
fi

echo "AVDs seen by emulator:"; emulator -list-avds || true
if ! emulator -list-avds | grep -qx "${AVD_NAME}"; then
  echo "ERROR: AVD '${AVD_NAME}' was not registered. Aborting."
  exit 1
fi

# ---------------------------------------------------------------------------
log "Booting the Android emulator (headless)"
start_emulator
sleep 5
if ! kill -0 "${EMU_PID}" 2>/dev/null; then
  echo "ERROR: the emulator process exited immediately after launch."
  exit 1
fi
wait_boot || exit 1
echo "Emulator booted."

log "Device ABI support (decides whether ARM-only APKs can install)"
for p in ro.product.cpu.abilist ro.product.cpu.abilist64 ro.product.cpu.abilist32 \
         ro.enable.native.bridge.exec ro.dalvik.vm.native.bridge; do
  echo "  ${p} = $(adb shell getprop ${p} 2>/dev/null | tr -d '\r')"
done

# ---------------------------------------------------------------------------
log "Root: 'adb root' (works on google_apis, refused on playstore images)"
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
fi

# ---------------------------------------------------------------------------
# ARM translation. Finding from a real run: the API 30 (Android 11)
# google_apis_playstore image ALREADY ships Google's libndk native bridge and
# advertises arm64-v8a / armeabi-v7a, so ARM-only APKs install with no extra
# work. (Newer images, e.g. API 33, do not.) Enabling this therefore just means
# "use API 30" - no Magisk module is required.
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
do_backup() {
  [ -n "${BACKUP_PASSWORD}" ] || { echo "No BACKUP_PASSWORD set - skipping backup."; return 0; }
  local WORK OUT BUNDLE STAMP
  WORK="$(mktemp -d)"
  STAMP="$(date -u +%Y%m%d-%H%M%S)"
  echo "Backing up user apps (root=${ROOT_OK}) at ${STAMP}"

  adb shell pm list packages -3 2>/dev/null | sed 's/^package://' | tr -d '\r' > "${WORK}/applist.txt" || true
  echo "User-installed apps: $(wc -l < "${WORK}/applist.txt")"

  while read -r pkg; do
    [ -n "${pkg}" ] || continue
    echo "  - ${pkg}"
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
      echo "     (no root available - private data not captured)"
      : > "${WORK}/apps/${pkg}/data.tar.gz"
    fi

    adb exec-out "tar -czf - -C /sdcard/Android/data ${pkg} 2>/dev/null" > "${WORK}/apps/${pkg}/external.tar.gz" 2>/dev/null || true
  done < "${WORK}/applist.txt"

  { echo "cloud-phone backup"; echo "timestamp: ${STAMP}"; echo "root: ${ROOT_OK}";
    echo "api-level: ${API_LEVEL}"; echo "target: ${TARGET}"; } > "${WORK}/MANIFEST.txt"
  adb shell pm list packages 2>/dev/null | tr -d '\r' > "${WORK}/packages-all.txt" || true

  BUNDLE="/tmp/cloudphone-bundle.tar.gz"
  tar -czf "${BUNDLE}" -C "${WORK}" .
  OUT="/tmp/cloudphone-backup-${STAMP}.tar.gz.enc"
  openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt \
    -pass env:BACKUP_PASSWORD -in "${BUNDLE}" -out "${OUT}"
  rm -rf "${WORK}" "${BUNDLE}"
  echo "Encrypted backup: $(du -h "${OUT}" | cut -f1)"

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
    git push -f origin "HEAD:refs/heads/backups" >/dev/null 2>&1 \
      && echo "Backup pushed to 'backups' (latest only)." \
      || echo "Backup push failed (needs 'contents: write' permission)."
  )
  rm -f "${OUT}"
  return 0
}

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
echo "#   Root: adb=${ROOT_OK} su=${SU_OK}  ARM translation: ${ARM_TRANSLATION}   #"
echo "#   Backup: $([ -n "${BACKUP_PASSWORD}" ] && echo "on, every ${BACKUP_INTERVAL_MIN} min -> branch 'backups'" || echo "off (no BACKUP_PASSWORD)")#"
echo "#   Stays up for ${DURATION_MIN} minutes.                         #"
echo "#                                                             #"
echo "###############################################################"
echo ""

# ---------------------------------------------------------------------------
log "Keeping the phone alive for ${DURATION_MIN} minutes"
NOW="$(date +%s)"
END=$(( NOW + DURATION_MIN * 60 ))
NEXT_BACKUP=$(( NOW + 60 ))
while [ "$(date +%s)" -lt "${END}" ]; do
  if ! kill -0 "${EMU_PID}" 2>/dev/null; then
    echo "Emulator process exited - stopping."
    break
  fi
  if [ -n "${BACKUP_PASSWORD}" ] && [ "$(date +%s)" -ge "${NEXT_BACKUP}" ]; then
    do_backup || echo "Backup attempt failed; will retry next interval."
    NEXT_BACKUP=$(( $(date +%s) + BACKUP_INTERVAL_MIN * 60 ))
  fi
  sleep 30
done

if [ -n "${BACKUP_PASSWORD}" ]; then
  log "Final backup"
  do_backup || echo "Final backup failed."
fi

echo "Session finished."
