# Diary Apps
Shop manager: home dashboard, stock (pictures, variations, low-stock limits, stock log), ledger (costs, reports), invoices
(pending / confirmed / cancelled, discount, advance, COD, one-time items, packaging weight, print A4/A5/80mm/58mm, PNG/JPG/PDF),
parcels with live Steadfast booking + status sync, customers (history check, quick fill), cloud backup, themes, subscription. English / বাংলা.
Native Android shell (WebView) + web UI in `app/src/main/assets/index.html`. Shop data is stored on the phone.

## Build the APK on GitHub
1. Push this folder to a GitHub repo (branch `main`).
2. Actions tab -> "Build Diary Apps APK" (runs on push, or press "Run workflow").
3. Open the finished run -> Artifacts -> `DiaryApps-debug-apk` -> unzip -> install `app-debug.apk`.

## Login, devices and subscription (Supabase)
1. Supabase -> SQL Editor -> run `supabase/setup.sql` once (safe to re-run). It converts `plan` / `status` to dropdown (enum) columns,
   removes the unsafe public policies, and adds phone+PIN login, the one-device lock and the device/IP log.
2. `app/src/main/assets/config.js` holds the Supabase URL, publishable key and the bKash/Nagad number.
3. Admin work in Table Editor -> `subscriptions` (pick from dropdowns, then Save):
   - approve a payment: `status` = active  (plan and expiry are filled automatically)
   - reject: `status` = rejected (+ optional `admin_note`)
   - many devices for one user: tick `allow_multi_device`
   - forgot PIN: set `pin_hash` to NULL; the user taps "Create account" and picks a new PIN
   - device / IP log: tables `device_logins` and `login_events`
