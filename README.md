# Cloud Phone

Spin up a **visual, touch-enabled Android phone** on a free GitHub Actions
runner, control it from any browser, and throw it away when you're done.

No server, no account, no local install. Press a button, wait a few minutes, and
get a URL that opens a live Android screen you can tap, swipe and type on.

Streaming is done with **scrcpy (H.264)** via [ws-scrcpy](https://github.com/NetrisTV/ws-scrcpy)
- not VNC. VNC sends screen-update rectangles and is choppy for a live phone;
H.264 video is what gives smooth 30-60fps.

---

## What you get

- A real Android emulator (choose the API level when you start it).
- A **visible screen** you can interact with - mouse/tap = touch, your keyboard
  types into Android.
- **Working internet** inside Android, so you can browse and download things.
- A **disposable** phone: when the job ends, everything is gone.

---

## How to use it

1. Open the **Actions** tab of this repository.
2. Pick **Cloud Phone** in the left sidebar.
3. Click **Run workflow**, set your options, and confirm:
   - **api_level** - e.g. `30`, `33`, `34`.
   - **duration_minutes** - how long to keep it alive (default `300`, max ~`340`).
   - **target** - `google_apis` (recommended), `google_apis_playstore`
     (adds the Play Store), or `default` (leanest).
4. Wait for the job to reach the **Launch cloud phone** step. It takes a few
   minutes to install the SDK, build the streaming server, and boot Android.
5. In the job log, look for the banner with your link:

   ```
   ###############################################################
   #   YOUR CLOUD PHONE IS LIVE  (scrcpy / H.264)                #
   #   Open this in your browser:                                #
   #     https://something-random.trycloudflare.com              #
   ###############################################################
   ```

6. Open that link, then **click your device in the list and choose
   `proxy over adb`** from the connection options. (The emulator's on-device
   server is only reachable over adb, so that's the option that works.)
7. When you're finished, **cancel the workflow run** (Actions -> the run ->
   Cancel) so the phone shuts down immediately instead of waiting out the timer.

---

## Options you can tweak

| Input | Default | Notes |
|---|---|---|
| `api_level` | `30` | Android version. 30 is a good balance of speed and app support. |
| `duration_minutes` | `300` | Keep-alive time. GitHub caps a job at 6 hours. |
| `target` | `google_apis` | `google_apis_playstore` gives you Play Services + Play Store. |

In `scripts/cloud-phone.sh` you can also change:

- `MAX_SIZE` (default `720`) - scrcpy downscales the longest screen edge to
  this. Lower = smoother. This is the single biggest lever on frame rate.
- The `hw.lcd.*` values written into the AVD config - the phone's own framebuffer
  resolution. Lower = less work for the (software) renderer.

---

## How it works

```
browser --https/wss--> trycloudflare.com --> runner:8000 (ws-scrcpy)
                                                  |
                                          adb --> Android emulator
                                                  (headless, KVM accelerated)
                                                  |
                                          scrcpy-server captures + encodes H.264
```

Everything (emulator, ws-scrcpy server, tunnel) runs inside a single script so
it stays alive for the whole job. GitHub Actions kills background processes when
a step ends, which is why the script sleeps at the end rather than returning.

The emulator runs **headless** (`-no-window`); scrcpy captures the device
framebuffer directly. There is no X server and no VNC in the path.

---

## Why it can still be slow

A free GitHub runner has **2 vCPUs and no GPU**, so Android runs with software
rendering. That is the hard ceiling on frame rate - no streaming change can fix
it. What the H.264 path fixes is the *second* bottleneck (VNC's inefficient
protocol). To go further, lower `MAX_SIZE`, lower the framebuffer resolution, or
use a larger (paid) runner with more vCPUs.

---

## Heads-up / limits

- **It's temporary.** The phone vanishes when the run ends. Nothing is saved.
- **No SIM.** No calls or SMS; apps that demand a phone number will complain.
- **GitHub Actions is a CI system.** Using runners as personal compute for long
  stretches sits outside what it's designed for. Keep sessions short. For
  something permanent, run [redroid](https://github.com/remote-android/redroid-doc)
  or [docker-android](https://github.com/budtmo/docker-android) on your own box.
- **The tunnel is public while it runs.** Anyone with the link can see the
  screen. Don't log into anything sensitive, and cancel the run when done.

---

## Credits

Google's Android emulator, [Genymobile/scrcpy](https://github.com/Genymobile/scrcpy),
[NetrisTV/ws-scrcpy](https://github.com/NetrisTV/ws-scrcpy), Cloudflare quick
tunnels, and the KVM enablement documented by GitHub.
