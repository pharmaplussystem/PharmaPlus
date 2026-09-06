# PharmaPlus — Multi-Pharmacy Management System

This version upgrades the existing PharmaPlus application while keeping Supabase authentication.

## Main changes
- Multi-drug POS basket: add several medicines to one sale.
- Walk-in or wholesale sale type.
- Wholesale business name appears on the receipt and is summarized in Reports.
- No standalone Customer module; wholesale customers are derived from sales.
- Click a wholesale business in Reports to see its complete sales history.
- Provisional/payment receipt can be printed before completing the sale.
- Completed sales print a normal sales receipt.
- Atomic multi-drug sale RPC prevents partial stock updates.
- Purchases are simplified to supplier name, amount used, date and invoice upload.
- Drugs are maintained only through Inventory.
- Financial reports by date: generated income, gross profit, purchase spending and stock value at cost.
- Inventory reports: expired, expiring soon, top selling drugs and total stock at hand.
- Reports can be printed, exported as PDF, or exported as Excel.
- Pharmacy registration: name, location, contact, email, currency and logo.
- Pharmacy details/logo appear on receipts and reports.
- Pharmacy workspaces are isolated with Row Level Security.

## Supabase setup
1. Open your Supabase project.
2. Go to **SQL Editor**.
3. Replace the old schema with the supplied `supabase_schema.sql` and run the entire file.
4. The migration preserves old tables/data where possible and creates the new multi-pharmacy/sales structures.
5. The first existing profile without a pharmacy is assigned a pharmacy workspace and administrator role if it was still staff.
6. New accounts automatically receive their own pharmacy workspace.
7. In the application, keep using your browser-safe **Project URL + Publishable/anon key**. Never use a service-role/secret key.

## Storage
The schema creates a public `pharmaplus-files` bucket for pharmacy logos and purchase invoices. Uploads are stored under the pharmacy UUID folder and protected by storage policies for writes.

## Running locally
Use a local web server rather than opening the HTML directly:

```bash
python -m http.server 8000
```

Then open `http://localhost:8000`.

## GitHub Pages
Upload the project files to your repository and enable GitHub Pages. Configure the Supabase URL/key from the application's connection settings.

## Important
This is a management-system starter. Before using real patient/clinical or financial data in production, perform a security/privacy review, audit access permissions, configure backups, and verify applicable Ugandan legal/regulatory requirements.


## IMPORTANT: Supabase configuration (V5)
Before opening or deploying the application, open `config.js`. Put your Supabase values here:

`window.PHARMAPLUS_SUPABASE_URL = "https://YOUR-PROJECT.supabase.co";`

`window.PHARMAPLUS_SUPABASE_KEY = "YOUR-PUBLISHABLE-KEY";`

Get them from **Supabase Dashboard -> Project Settings -> API**. Use the browser-safe **Publishable key** (`sb_publishable_...`) or legacy `anon` key. Never use a secret/service_role key in the browser.

The app also retains its on-screen connection settings as a fallback, but `config.js` is the recommended and easiest deployment method.
