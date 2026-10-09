# Cloud Phone

Spin up a **visual, touch-enabled Android phone** on a free GitHub Actions
runner, control it from any browser, and throw it away when you're done.

No server, no account, no local install. You press a button, wait a few
minutes, and get a URL that opens a live Android screen you can tap, swipe and
type on.

---

## What you get

- A real Android emulator (choose the API level when you start it).
- A **visible screen** you can interact with - click/tap to touch, your
  keyboard types into Android.
- **Working internet** inside Android, so you can browse and download things.
- A **disposable** phone: when the job ends, everything is gone.

It is not tuned for gaming and doesn't need to be. It's a quick, throwaway
device for installing apps and pulling files down over a fast connection.

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
   minutes to boot Android.
5. In the job log, look for the banner:

   ```
   ###############################################################
   #   YOUR CLOUD PHONE IS LIVE                                  #
   #   Open this link in any browser:                            #
   #     https://something-random.trycloudflare.com/vnc.html?...
   ###############################################################
   ```

6. Open that link. You now have a phone in your browser tab.
   - **Click / tap** on the screen = touch.
   - **Type** on your keyboard = typing into Android.
   - Use the noVNC sidebar to send Home / Back / rotate, and to scale the screen.
7. When you're finished, **cancel the workflow run** (Actions -> the run ->
   Cancel) so the phone shuts down immediately instead of waiting out the timer.

The phone dies on its own when `duration_minutes` is up, or when the run is
cancelled - either way the runner and everything on it is discarded.

---

## Options you can tweak

| Input | Default | Notes |
|---|---|---|
| `api_level` | `30` | Android version. 30 is a good balance of speed and app support. |
| `duration_minutes` | `300` | Keep-alive time. GitHub caps a job at 6 hours. |
| `target` | `google_apis` | `google_apis_playstore` gives you Play Services + Play Store. |

To change the default screen size or device profile, edit `DEVICE` /
`XDISPLAY_SIZE` at the top of `scripts/cloud-phone.sh`.

---

## How it works

```
browser --https--> trycloudflare.com --tunnel--> runner:6080 (noVNC)
                                                      |
                                              websockify -> x11vnc :5900
                                                      |
                                              Xvfb :99  (virtual screen)
                                                      |
                                              Android emulator (KVM accelerated)
```

Everything (Xvfb, emulator, VNC, tunnel) runs inside a single script so it stays
alive for the whole job. GitHub Actions kills background processes when a step
ends, which is why the script sleeps at the end rather than returning.

---

## Heads-up / limits

- **It's temporary.** The phone vanishes when the run ends. Nothing is saved.
- **No SIM.** No calls or SMS; apps that demand a phone number will complain.
- **GitHub Actions is a CI system.** Using runners as personal compute for long
  stretches sits outside what it's designed for. Keep sessions short and don't
  treat this as an always-on phone. For something permanent, run
  [redroid](https://github.com/remote-android/redroid-doc) or
  [docker-android](https://github.com/budtmo/docker-android) on your own box.
- **The tunnel is public while it runs.** Anyone with the link can see the
  screen. Don't log into anything sensitive, and cancel the run when done.

---

## Credits

Built on the shoulders of: Google's Android emulator, `xvfb`/`x11vnc`/`noVNC`,
Cloudflare quick tunnels, and the KVM enablement documented by GitHub.
