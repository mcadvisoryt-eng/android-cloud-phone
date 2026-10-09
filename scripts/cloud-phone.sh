#!/usr/bin/env bash
#
# cloud-phone.sh - boot a visual, touch-enabled Android "cloud phone" on a
# GitHub Actions runner and expose it to the browser through a public tunnel.
#
# Everything runs inside ONE process tree on purpose: GitHub Actions kills any
# background process when a step ends, so the emulator, the VNC stack and the
# tunnel must all live inside this single script, which then sleeps to keep the
# job (and therefore the phone) alive.
#
set -euo pipefail

API_LEVEL="${API_LEVEL:-30}"
ARCH="${ARCH:-x86_64}"
TARGET="${TARGET:-google_apis}"
DURATION_MIN="${DURATION_MIN:-300}"
DEVICE="${DEVICE:-pixel_2}"

DISP=":99"
VNC_PORT=5900
NOVNC_PORT=6080
XDISPLAY_SIZE="1280x2100x24"

# Use our OWN SDK directory. Do NOT inherit the runner's $ANDROID_HOME: it points
# at /usr/local/lib/android/sdk, which we delete below to free space, and which
# is root-owned anyway.
export ANDROID_HOME="$HOME/android-sdk"
export ANDROID_SDK_ROOT="${ANDROID_HOME}"
export DISPLAY="${DISP}"
export PATH="${ANDROID_HOME}/cmdline-tools/latest/bin:${ANDROID_HOME}/platform-tools:${ANDROID_HOME}/emulator:${PATH}"

log() { echo -e "\n=== $* ==="; }

# ---------------------------------------------------------------------------
log "Freeing disk space"
sudo rm -rf /usr/local/lib/android /usr/share/dotnet /opt/ghc \
            /opt/hostedtoolcache/CodeQL /usr/local/share/boost 2>/dev/null || true
df -h / | tail -1

# ---------------------------------------------------------------------------
log "Installing display + VNC packages"
sudo apt-get update -qq
sudo apt-get install -y -qq \
  xvfb x11vnc novnc websockify fluxbox xterm \
  libpulse0 libnss3 wget curl unzip >/dev/null

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
  -n cloudphone \
  -k "${IMAGE}" \
  --device "${DEVICE}" \
  --force >/dev/null

# ---------------------------------------------------------------------------
log "Starting virtual display"
Xvfb "${DISP}" -screen 0 "${XDISPLAY_SIZE}" -ac +extension GLX +render -noreset &
sleep 3
fluxbox >/dev/null 2>&1 &

# ---------------------------------------------------------------------------
log "Booting the Android emulator (this takes a few minutes)"
emulator -avd cloudphone \
  -gpu swiftshader_indirect \
  -no-snapshot -no-audio -no-boot-anim \
  -camera-back none -camera-front none \
  -netdelay none -netspeed full &
EMU_PID=$!

adb start-server >/dev/null 2>&1 || true
adb wait-for-device
timeout 900 bash -c 'while [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d "\r\n")" != "1" ]; do sleep 5; done' \
  || { echo "Emulator failed to boot in time"; exit 1; }
adb shell input keyevent 82 >/dev/null 2>&1 || true
echo "Emulator booted."

# ---------------------------------------------------------------------------
log "Starting x11vnc + noVNC (browser viewer)"
x11vnc -display "${DISP}" -forever -shared -nopw -rfbport "${VNC_PORT}" -localhost \
  >/tmp/x11vnc.log 2>&1 &
sleep 2
websockify --web /usr/share/novnc "${NOVNC_PORT}" "localhost:${VNC_PORT}" \
  >/tmp/websockify.log 2>&1 &
sleep 2

# ---------------------------------------------------------------------------
log "Opening a public tunnel (Cloudflare quick tunnel - no account needed)"
curl -sSLo /tmp/cloudflared \
  "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
chmod +x /tmp/cloudflared
/tmp/cloudflared tunnel --url "http://localhost:${NOVNC_PORT}" --no-autoupdate \
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
echo "#   YOUR CLOUD PHONE IS LIVE                                  #"
echo "#                                                             #"
echo "#   Open this link in any browser:                            #"
echo "#     ${URL}/vnc.html?autoconnect=1&resize=scale"
echo "#                                                             #"
echo "#   Click / tap = touch. Your keyboard types into Android.    #"
echo "#   It stays up for ${DURATION_MIN} minutes, then disappears.     #"
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
