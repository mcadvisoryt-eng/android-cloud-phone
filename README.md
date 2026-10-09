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

The default is **`google_apis_playstore`** - Android with **Google Play Services
and the Play Store**. This matters more than anything else for "do my apps work":

- Apps that use Google sign-in, Maps, Firebase, push notifications, ads, or the
  Play Billing library **crash or hang on startup without Play Services**. The
  `google_apis` image lacks them.
- **ARM-only apps need the API 30 image.** The Android 11 (API 30)
  `google_apis_playstore` image ships Google's **libndk** native bridge and
  advertises `arm64-v8a` / `armeabi-v7a`, so ARM-only APKs install and run. Newer
  images such as API 33 do **not** include it, and ARM-only APKs fail there with
  *"App not installed as app isn't compatible with your phone"*. Set
  **arm_translation: yes** to force API 30 for this.

**The trade-off:** Play Store images are production builds, so `adb root` is
*refused*. On that image root comes from **Magisk** only. If Magisk fails, the
phone still works but the encrypted backup can't read private app data.

---

## How to use it

1. **Actions** tab -> **Cloud Phone** -> **Run workflow**.
2. Set the inputs:
   - **api_level** - `30` for ARM-only apps, otherwise `33`.
   - **duration_minutes** - default `300`; hard cap ~`340`.
   - **target** - `google_apis_playstore` (default, apps work), `google_apis`
     (guaranteed `adb root`, no Play Services), or `default`.
   - **magisk** - `yes`/`no`.
   - **arm_translation** - `yes` to force API 30 so arm64-only APKs run.
3. Wait ~15-20 minutes.
4. In the job log, find the banner:
   ```
   #   YOUR CLOUD PHONE IS LIVE  (scrcpy / H.264)
   #   Open this in your browser:
   #     https://<random>.trycloudflare.com
   ```
5. Open it, **click your device, and pick `proxy over adb`**. Mouse/tap = touch.
6. Install/log in, use the phone, then **cancel the run** when done.

---

## Backups

- Every **15 minutes** (`BACKUP_INTERVAL_MIN`) the phone snapshots all
  **user-installed apps** - each APK plus its private data
  (`/data/user/0/<pkg>`, where browser cookies, saved logins and profiles live).
- Encrypted with **AES-256-CBC** using `BACKUP_PASSWORD`.
- Force-pushed to the **`backups`** branch, which keeps **only the newest**
  snapshot (a fresh single-file commit replaces the branch each time).

Decrypt with:

```bash
openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 \
  -in cloudphone-backup-YYYYmmdd-HHMMSS.tar.gz.enc -out backup.tar.gz
tar -xzf backup.tar.gz
```

**Honest caveat:** restoring onto a *different* device is not always clean -
Chrome sync tokens and some app data are bound to the device keychain. Treat this
as a capture you can inspect and partially restore, not a guaranteed restore.

---

## Root

- **`adb root`** - works on `google_apis`; refused on Play Store images.
- **Magisk** via [rootAVD](https://github.com/newbit1/rootAVD), pinned to
  **Magisk 25.2** (Magisk 26+ needs the manual "FAKEBOOTIMG" tap and cannot run
  unattended).

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
- **ARM-only apps:** use **API 30** (set `arm_translation: yes`), which ships
  libndk translation. API 33 and newer do not, so ARM-only apps fail there.
- **GitHub Actions is a CI system.** Keep personal sessions short.
- **The tunnel is public while it runs**, and the repo is public - the backup is
  protected *only* by your `BACKUP_PASSWORD`. Use a strong one.
