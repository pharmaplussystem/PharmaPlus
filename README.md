# PharmaPlus - Pharmacy Management System

This build is based on the working PharmaPlus Supabase multi-pharmacy application.

## Roles
- Admin: full control
- Manager: staff management and operational role assignment
- Pharmacist: medicines, POS, sales and receipts
- Inventory Officer: stock and purchases
- Staff: basic access
- Cashier: retired; Pharmacist handles former cashier responsibilities

## Updated modules
- Medicines: generic name, brand, category, batch, expiry, quantity, buy/sell price, date entered
- Medicine selector for previously entered medicines
- Medicine Details with stocking and sales history
- Edit Medicine inside Details
- Archive/restore instead of destructive deletion in normal inventory workflow
- POS search showing brand, batch and expiry
- Receipts with generic (brand), batch and italic return notice
- Purchases with optional invoice document and no Recorded By field
- Reports grouped into Financial, Inventory and Customer
- Financial reports restricted to Admin and Manager
- Expenses restricted to Admin and Manager
- Expense categories: Rent, Bills, Wages, Tax, Subscriptions, Others
- Optional supporting expense document upload
- Net profit = gross profit - expenses
- Confirmation prompts for important actions

## Supabase setup
Run `supabase_schema.sql` completely in the Supabase SQL Editor. Keep your existing working `config.js` values.
