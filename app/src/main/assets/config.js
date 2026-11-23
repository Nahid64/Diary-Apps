// Edit the values below, commit, and let GitHub Actions rebuild the APK.
window.APP_CONFIG = {
  // Supabase project (Project Settings -> API). The publishable key is safe to ship in the app.
  SUPABASE_URL: "https://rlwlrchdwclbishenmvq.supabase.co",
  SUPABASE_ANON_KEY: "sb_publishable_5jP0JFQdc8r7dGnhVYI7pg_A_FQhxqE",

  // Where customers send the subscription payment
  PAYMENT_NUMBERS: { bKash: "01756475499", Nagad: "01756475499" },
  PAYMENT_METHODS: ["bKash", "Nagad"],
  PAYMENT_ACCOUNT_TYPE: "Personal",   // shown next to the number, e.g. Personal / Agent / Merchant

  PLAN_PRICES: { monthly: 199, yearly: 1999 },
  SUPPORT_PHONE: ""
};
