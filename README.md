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

## Which image? (this is the important one)

The default is now **`google_apis_playstore`** - Android with **Google Play
Services and the Play Store**. This matters more than anything else for "do my
apps work":

- Apps that use Google sign-in, Maps, Firebase, push notifications, ads, or the
  Play Billing library **crash or hang on startup without Play Services**. The
  `google_apis` image (Google APIs, no Play Store) lacks them, which is exactly
  the "it launched then died" symptom.
- Play Store images are also where you can install apps normally from the Play
  Store, rather than sideloading APKs.

**The trade-off:** Play Store images are production builds, so `adb root` is
*refused*. On that image, root comes from **Magisk** only. If Magisk fails, the
phone still works but the encrypted backup can't read private app data.

If you'd rather have guaranteed `adb root` (and reliable backups) over app
compatibility, switch **target** back to `google_apis`.

---

## How to use it

1. **Actions** tab -> **Cloud Phone** -> **Run workflow**.
2. Set the inputs:
   - **api_level** - default `33` (Android 13). Raise it if an app demands newer.
   - **duration_minutes** - default `300`; hard cap ~`340`.
   - **target** - `google_apis_playstore` (default, apps work), `google_apis`
     (guaranteed `adb root`, no Play Services), or `default` (leanest, no Google).
   - **magisk** - `yes`/`no`. On the Play Store image you want `yes`, since it's
     the only root path there.
3. Wait ~15-20 minutes.
4. In the job log, find the banner:
   ```
   #   YOUR CLOUD PHONE IS LIVE  (scrcpy / H.264)
   #   Open this in your browser:
   #     https://<random>.trycloudflare.com
   ```
5. Open it, **click your device, and pick `proxy over adb`**. Mouse/tap = touch,
   your keyboard types into Android.
6. Sign into the Play Store, install what you need, use the phone, then **cancel
   the run** when done.

---

## Backups

- Every **15 minutes** (`BACKUP_INTERVAL_MIN`) the phone snapshots all
  **user-installed apps** - each APK plus its private data
  (`/data/user/0/<pkg>`, where browser cookies, saved logins and profiles live).
- Encrypted with **AES-256-CBC** using `BACKUP_PASSWORD`, then force-pushed to a
  branch called **`backups`** (one file, replaced each time).
- A final snapshot runs when the session ends.

Decrypt with:

```bash
openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 \
  -in cloudphone-backup-YYYYmmdd-HHMMSS.tar.gz.enc -out backup.tar.gz
tar -xzf backup.tar.gz
```

**Honest caveat:** restoring onto a *different* device is not always clean -
Chrome sync tokens and some app data are bound to the device keychain. Treat this
as a capture you can inspect and partially restore, not a guaranteed restore.
Since the emulator is fresh each run, the useful backup is the one taken near the
end of your session - the periodic snapshots cover that.

---

## Root

- **`adb root`** - works on `google_apis`; refused on Play Store images.
- **Magisk** via [rootAVD](https://github.com/newbit1/rootAVD), pinned to
  **Magisk 25.2**. Magisk **26+** needs the "FAKEBOOTIMG" flow, which requires a
  manual tap in the Magisk app and cannot run unattended; 25.2 (Android 13
  capable) patches non-interactively.

Magisk is **best-effort** - if it fails the run continues. Check the log line
`root after Magisk step: adb=... su=...`.

**KernelSU is not possible here** - it's kernel-based and needs a custom kernel
compiled with KernelSU; none is published for the Android emulator.

---

## Tuning

In `scripts/cloud-phone.sh`:

- `MAX_SIZE` (default `640`) - scrcpy downscale. Biggest lever on frame rate.
- `hw.lcd.*` - the phone's framebuffer (720x1280).
- `BACKUP_INTERVAL_MIN` (default `15`).
- `MAGISK_VER` - must be `< 26` to stay unattended.

---

## Limits

- **It's temporary.** The phone vanishes when the run ends; only the encrypted
  backup persists.
- **No SIM.** No calls or SMS.
- **2 vCPUs, no GPU** - software rendering is the ceiling on frame rate.
- **x86_64 emulator:** apps that ship *only* ARM native libraries may still fail.
  Most Play Store apps are fine, but a few heavy/game apps are ARM-only.
- **GitHub Actions is a CI system.** Keep personal sessions short.
- **The tunnel is public while it runs**, and the repo is public - the backup is
  protected *only* by your `BACKUP_PASSWORD`. Use a strong one.
