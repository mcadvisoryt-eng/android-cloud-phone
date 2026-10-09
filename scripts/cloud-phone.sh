#!/usr/bin/env bash
#
# cloud-phone.sh - boot a visual, touch-enabled Android "cloud phone" on a
# GitHub Actions runner and stream it to the browser with scrcpy (H.264)
# through ws-scrcpy, exposed over a public Cloudflare tunnel.
#
# Why not noVNC: VNC/RFB sends screen-update rectangles, not video. It is slow
# and choppy for a live phone. scrcpy captures the Android framebuffer directly
# and encodes H.264, which is what actually gives smooth 30-60fps.
#
# The emulator runs HEADLESS (-no-window): scrcpy captures the device itself, so
# there is no X server, no VNC, and no double rendering.
#
# Everything lives in ONE process tree: GitHub Actions kills background
# processes when a step ends, so this script starts everything and then sleeps.
#
set -euo pipefail

API_LEVEL="${API_LEVEL:-30}"
ARCH="${ARCH:-x86_64}"
TARGET="${TARGET:-google_apis}"
DURATION_MIN="${DURATION_MIN:-300}"
DEVICE="${DEVICE:-pixel_2}"
AVD_NAME="cloudphone"
MAX_SIZE="${MAX_SIZE:-720}"     # scrcpy: downscale longest edge to this
WS_PORT="${WS_PORT:-8000}"      # ws-scrcpy web UI

export ANDROID_HOME="$HOME/android-sdk"
export ANDROID_SDK_ROOT="${ANDROID_HOME}"
export PATH="${ANDROID_HOME}/cmdline-tools/latest/bin:${ANDROID_HOME}/platform-tools:${ANDROID_HOME}/emulator:${PATH}"
# Pin AVD + user homes so avdmanager and emulator agree on where AVDs live.
export ANDROID_USER_HOME="$HOME/.android"
export ANDROID_AVD_HOME="$HOME/.android/avd"
mkdir -p "${ANDROID_USER_HOME}" "${ANDROID_AVD_HOME}"

log() { echo -e "\n=== $* ==="; }

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

# Shrink the phone's own framebuffer. Software rendering cost scales with pixel
# count, so 720x1280 is dramatically lighter than 1080x1920 on 2 vCPUs.
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
emulator -avd "${AVD_NAME}" \
  -no-window -no-audio -no-boot-anim -no-snapshot \
  -gpu swiftshader_indirect \
  -camera-back none -camera-front none \
  -netdelay none -netspeed full &
EMU_PID=$!

sleep 5
if ! kill -0 "${EMU_PID}" 2>/dev/null; then
  echo "ERROR: the emulator process exited immediately after launch."
  exit 1
fi

adb start-server >/dev/null 2>&1 || true
timeout 600 adb wait-for-device || { echo "No emulator device appeared within 10 minutes."; exit 1; }
timeout 900 bash -c 'while [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d "\r\n")" != "1" ]; do sleep 5; done' \
  || { echo "Emulator failed to finish booting in time"; exit 1; }
echo "Emulator booted."

# ---------------------------------------------------------------------------
log "Building ws-scrcpy (H.264 streaming server)"
rm -rf "$HOME/ws-scrcpy"
git clone --depth 1 https://github.com/NetrisTV/ws-scrcpy.git "$HOME/ws-scrcpy"
cd "$HOME/ws-scrcpy"

# Build flags: drop the ADB-shell feature (needs node-pty native build) and make
# the on-device server reachable over adb, which is what an emulator needs.
cat > build.config.override.json <<'JSON'
{
  "INCLUDE_ADB_SHELL": false,
  "SCRCPY_LISTENS_ON_ALL_INTERFACES": false
}
JSON

# --ignore-scripts skips native builds we don't need; --omit=optional skips Appium.
npm install --ignore-scripts --omit=optional --no-audit --no-fund
npm run dist

# ---------------------------------------------------------------------------
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
echo "#   Mouse/tap = touch. H.264 stream = smooth.                 #"
echo "#   Stays up for ${DURATION_MIN} minutes.                         #"
echo "#                                                             #"
echo "###############################################################"
echo ""

# ---------------------------------------------------------------------------
log "Keeping the phone alive for ${DURATION_MIN} minutes"
END=$(( $(date +%s) + DURATION_MIN * 60 ))
while [ "$(date +%s)" -lt "${END}" ]; do
  if ! kill -0 "${EMU_PID}" 2>/dev/null; then
    echo "Emulator process exited - stopping."
    break
  fi
  sleep 30
done

echo "Session finished."
