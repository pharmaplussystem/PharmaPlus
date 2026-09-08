# PharmaPlus V7

Professional responsive pharmacy management system with Supabase authentication/database.

## V7 highlights
- Medicine history suggestions while entering new medicines
- Generic (Brand) display throughout the system
- Separate Wholesale and Retail prices
- POS automatically selects the correct price by customer type
- Batch and expiry visible during sales and on receipts
- Provisional receipts create Pending sales
- Stock is deducted ONLY when a pending sale is completed (or when a direct sale is completed)
- Pending sales can be completed or rejected
- Sales filters: All, Completed, Pending, Rejected
- Inventory rows open Medicine Details directly; no inventory Actions button
- Medicine Actions drawer lives inside Details
- Edit, quantity/price changes, archive/restore and permanent delete from Details
- Admin/Manager controls for quantity and pricing
- Individual report tiles with independent Print/PDF/Excel actions
- Financial reports remain restricted to Admin/Manager
- Responsive layout with no horizontal page scrolling

## Supabase
Run the complete `supabase_schema.sql` in the existing Supabase project before using V7.
Never expose a Supabase service-role/secret key in the frontend.
