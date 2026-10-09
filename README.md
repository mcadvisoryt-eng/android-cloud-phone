# Cloud Phone

Spin up a **visual, touch-enabled, rooted Android phone** on a free GitHub
Actions runner, control it from any browser, and have it **automatically back up
your apps and their data** - encrypted - to this repo. Throw it away when done.

Streaming uses **scrcpy (H.264)** via [ws-scrcpy](https://github.com/NetrisTV/ws-scrcpy),
not VNC. H.264 video is what gives smooth playback; VNC's screen-update protocol
is choppy for a live phone.

---

## Before you start

**Add a repo secret called `BACKUP_PASSWORD`.** Settings -> Secrets and variables
-> Actions -> New repository secret. The backup is AES-256 encrypted with this
password; without it, backups are skipped (everything else still works). Only you
know the password - keep it safe, or the backup is unrecoverable.

---

## How to use it

1. **Actions** tab -> **Cloud Phone** -> **Run workflow**.
2. Set the inputs:
   - **api_level** - default `33` (Android 13).
   - **duration_minutes** - how long to keep it alive (default `300`; hard cap ~`340`).
   - **target** - `google_apis` (recommended: Google APIs *and* working `adb root`),
     `google_apis_playstore` (adds the Play Store, but `adb root` is refused there,
     so root then depends entirely on Magisk succeeding), or `default`.
   - **magisk** - `yes`/`no`. `no` skips the (best-effort) Magisk install.
3. Wait ~15 minutes: SDK install, Android boot, Magisk patch, streaming build.
4. In the job log, find the banner with your link:
   ```
   #   YOUR CLOUD PHONE IS LIVE  (scrcpy / H.264)
   #   Open this in your browser:
   #     https://<random>.trycloudflare.com
   ```
5. Open it, **click your device, and pick `proxy over adb`**. Mouse/tap = touch,
   your keyboard types into Android.
6. Install/log into Chrome or Firefox, use the phone, then **cancel the run**
   when you're done.

---

## Backups

- Every **15 minutes** (`BACKUP_INTERVAL_MIN`) the phone snapshots all
  **user-installed apps** - each app's APK plus its private data
  (`/data/user/0/<pkg>`, which is where browser cookies, saved logins and
  profiles live) and any external data.
- The bundle is tarred and **encrypted with AES-256-CBC** using `BACKUP_PASSWORD`.
- It is force-pushed to a branch called **`backups`** (one file, replaced each
  time, so the repo does not grow unbounded).
- A final backup runs when the session ends.

**To decrypt** (on any machine with OpenSSL):

```bash
openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 \
  -in cloudphone-backup-YYYYmmdd-HHMMSS.tar.gz.enc \
  -out backup.tar.gz
tar -xzf backup.tar.gz
```

You'll get `apps/<package>/` with the APKs and `data.tar.gz` per app.

**Caveats, honestly:** restoring this onto a *different* device is not always
clean - some apps (Chrome sync tokens, banking apps, Signal) bind their data to
the device keychain and will complain. This is a *capture* you can inspect and
partially restore, not a guaranteed full restore. Also, because the emulator is
fresh each run, the useful backup is the one taken near the end of your session -
the periodic snapshots cover that.

---

## Root

Two layers, deliberately:

1. **`adb root`** - on `google_apis` images this just works and gives a root
   shell. It's what makes the backup reliable.
2. **Magisk** - installed via [rootAVD](https://github.com/newbit1/rootAVD),
   pinned to **Magisk 25.2**. That version is deliberate: Magisk **26+** requires
   the "FAKEBOOTIMG" flow, which needs a manual tap inside the Magisk app and
   therefore cannot run unattended. 25.2 (which supports Android 13) can be
   patched non-interactively.

The Magisk step is **best-effort**: if it fails, the run continues and the backup
still works via `adb root`. Check the log line `root after Magisk step:`.

**KernelSU is not an option here.** It's kernel-based and needs a custom kernel
compiled with KernelSU; no such kernel is published for the Android emulator.
Magisk is the practical choice.

---

## Tuning

In `scripts/cloud-phone.sh`:

- `MAX_SIZE` (default `640`) - scrcpy downscales the longest edge to this.
  **The biggest lever on frame rate/latency.** Try `540` or `480`.
- `hw.lcd.*` in the AVD config - the phone's own framebuffer (720x1280).
- `BACKUP_INTERVAL_MIN` (default `15`) - how often to snapshot.
- `MAGISK_VER` - pin a different Magisk (must be `< 26` to stay unattended).

---

## How it works

```
browser --https/wss--> trycloudflare.com --> runner:8000 (ws-scrcpy)
                                                 |
                                        adb --> Android emulator (headless, KVM)
                                                 |
                                        scrcpy-server encodes H.264
                                                 |
                              adb root / Magisk su --> tar app data
                                                 |
                              openssl AES-256 --> git push origin backups
```

Everything runs inside one script because GitHub Actions kills background
processes when a step ends; the script sleeps at the end to hold the job open.

---

## Limits

- **It's temporary.** The phone vanishes when the run ends; only the encrypted
  backup persists.
- **No SIM.** No calls or SMS.
- **2 vCPUs, no GPU** - Android runs on software rendering. That's the ceiling on
  frame rate; H.264 fixed the protocol half, not the renderer half.
- **GitHub Actions is a CI system.** Long personal sessions sit outside what it's
  designed for. Keep them short.
- **The tunnel is public while it runs**, and the repo is public - the backup is
  protected *only* by your `BACKUP_PASSWORD`. Use a strong one.
