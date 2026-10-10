# Cloud Phone

Spin up a **visual, touch-enabled Android phone** on a free GitHub Actions
runner, control it from any browser, and get **ntfy notifications** about what
it's doing. Light by default; add Google services, root, or backups only if you
want them.

Streaming uses **scrcpy (H.264)** via [ws-scrcpy](https://github.com/NetrisTV/ws-scrcpy),
not VNC. H.264 video is what gives smooth playback.

---

## Secrets (all optional, but recommended)

Settings -> Secrets and variables -> Actions -> New repository secret.

| Secret | What it does |
|---|---|
| `NTFY_TOPIC` | Your [ntfy](https://ntfy.sh) topic. Enables all notifications. |
| `NTFY_SERVER` | Optional. A self-hosted ntfy server (defaults to `https://ntfy.sh`). |
| `BACKUP_PASSWORD` | Enables the encrypted app-data backup (AES-256). |

Subscribe to your topic in the ntfy app (or open `https://ntfy.sh/<topic>`) and
you'll get push messages for the events below.

---

## Defaults (deliberately light)

| Setting | Default | Why |
|---|---|---|
| `api_level` | **29** (Android 10) | Far lighter than 33; boots faster, runs smoother. Use `24` (Android 7) for even less. |
| `target` | **`default`** (AOSP) | No Google services = no bloat, fastest boot. |
| `magisk` | **`no`** | Root is optional; skip it and the run is quicker. |
| `arm_translation` | **`no`** | Only needed for ARM-only APKs. |

Add Google services by choosing `google_apis` (Google APIs) or
`google_apis_playstore` (Play Store + Play Services) - needed if apps use Google
sign-in, Firebase, push notifications, ads, or Play Billing.

---

## Notifications (ntfy)

Set `NTFY_TOPIC` and the script pushes a notification for:

- **Starting** - job began, with the Android version and image.
- **VM started** - the emulator booted.
- **LIVE** - the phone is up, including its URL and session length.
- **Root** - result of the optional Magisk step (`adb=... su=...`).
- **Backup pushed** - an encrypted snapshot landed on the `backups` branch.
- **Status** - every `NOTIFY_INTERVAL_MIN` (default 30): **remaining time**,
  uptime, user-app count, free RAM, root state, and **time until the next
  backup**.
- **Restarting / back up** - only if `RESTART_EVERY_MIN` is set (default 0 = off);
  reboots the emulator on a schedule and tells you.
- **DIED** - the emulator exited unexpectedly.
- **Ended** - the session finished.

Tune the cadence with `NOTIFY_INTERVAL_MIN` and enable scheduled reboots with
`RESTART_EVERY_MIN` (both in the workflow's `env:`).

---

## How to use it

1. **Actions** tab -> **Cloud Phone** -> **Run workflow**.
2. Set the inputs (defaults are fine for a light, fast phone).
3. Wait ~10-15 minutes (less than before - no Google image, no root step).
4. In the job log, find the banner:
   ```
   #   YOUR CLOUD PHONE IS LIVE  (scrcpy / H.264)
   #     https://<random>.trycloudflare.com
   ```
5. Open it, **click your device, and pick `proxy over adb`**. Mouse/tap = touch.
6. When done, **cancel the run**.

---

## ARM-only apps

Some apps (e.g. MovieBox) ship only `arm64-v8a` libraries and refuse to install
on an x86_64 emulator. The **API 30** image ships Google's **libndk** native
bridge, so they work there - set **arm_translation: yes** (which forces API 30).
API 33 and newer do **not** include it, and such apps fail with *"app isn't
compatible with your phone"*.

---

## Backups

- Every **15 minutes** the phone snapshots all **user-installed apps** - APK plus
  private data (`/data/user/0/<pkg>`, where browser cookies and saved logins
  live). Private data needs root; without it only APKs are captured.
- Encrypted with **AES-256-CBC** using `BACKUP_PASSWORD`.
- Force-pushed to the **`backups`** branch, keeping **only the newest** snapshot.

```bash
openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 \
  -in cloudphone-backup-YYYYmmdd-HHMMSS.tar.gz.enc -out backup.tar.gz
tar -xzf backup.tar.gz
```

**Caveat:** restoring onto a *different* device is not always clean - some app
data is bound to the device keychain.

---

## Root (optional)

- On `default` / `google_apis` images, **`adb root`** just works.
- **Magisk** (via [rootAVD](https://github.com/newbit1/rootAVD), pinned to 25.2)
  is best-effort and off by default. **KernelSU is not possible** - it needs a
  custom kernel that isn't published for the emulator.

---

## Tuning (in `scripts/cloud-phone.sh`)

- `MAX_SIZE` (default `640`) - scrcpy downscale. Biggest lever on frame rate.
- `hw.lcd.*` - the phone's framebuffer (720x1280).
- `NOTIFY_INTERVAL_MIN`, `RESTART_EVERY_MIN`, `BACKUP_INTERVAL_MIN`.

---

## Limits

- **Temporary.** The phone vanishes when the run ends.
- **No SIM.** No calls or SMS.
- **2 vCPUs, no GPU** - software rendering is the ceiling on frame rate.
- **GitHub Actions is a CI system.** Keep sessions short.
- **The tunnel is public while it runs**, and the repo is public - the backup is
  protected *only* by `BACKUP_PASSWORD`.
