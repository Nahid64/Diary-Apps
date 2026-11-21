# Diary Apps
Shop diary: stock, ledger, invoices (print / PNG / PDF), customers, courier settings, subscription. English / বাংলা.
Native Android shell (WebView) + web UI in `app/src/main/assets/index.html`. Shop data is stored on the phone.

## Build the APK on GitHub
1. Push this folder to a GitHub repo (branch `main`).
2. Actions tab -> "Build Diary Apps APK" (runs on push, or press "Run workflow").
3. Open the finished run -> Artifacts -> `DiaryApps-debug-apk` -> unzip -> install `app-debug.apk`.

## Subscription approval (Supabase)
1. Supabase -> SQL Editor -> run `supabase/setup.sql` once (it also removes the unsafe public policies from the `subscriptions` table).
2. `app/src/main/assets/config.js` holds the Supabase URL, publishable key and the bKash/Nagad number.
3. A customer's payment shows up in Table Editor -> `subscriptions` with `status = pending` (see `sender_phone`, `trx_id`).
   Verify it in your bKash/Nagad app, then set `status` to `active` (plan and expiry are filled automatically).
   Set `rejected` (optionally with `admin_note`) to decline.
