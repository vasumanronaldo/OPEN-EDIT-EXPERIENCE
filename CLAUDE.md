# Edit Experience — Private Inventory Platform

A multi-tenant inventory platform for a luxury resale business. One private warehouse cloud holds all stock. Each account sees only a controlled slice of it.

## Who uses it

- **Admin (store / warehouse)** — owns the vault. Adds stock, sets cost, issues reseller accounts and their rules. Sees everything.
- **Reseller (consigner / dealer)** — lists own stock plus store stock cleared to them. Sets client prices. Invites and manages their own B2B clients within admin-set rules.
- **B2B Client** — logs in with a unique key, sees only the gated catalogue for the resellers they are keyed into. Can be keyed to several resellers and switch between them.

## Non-negotiable invariants

These are the whole point of the product. Never break them.

1. **Clients never see cost, basis, margin, consigner identity, or any other client.** Client inventory reads go through the `get_my_catalog(slug)` RPC only, which selects safe columns. Clients have no direct select on `pieces` / `listings`.
2. **Resellers never see another reseller's rows.** Enforced by RLS (`reseller_id = auth.uid()`).
3. **No stock change commits on one party's say-so.** Every movement (add, remove, sold, returned, price change, settled) goes through `propose_movement` then `resolve_movement`. The proposer's counterparty is the only one who can approve or deny. Never write `movements` or flip `pieces.status` directly from the app.
4. **The ledger is shared and append-only in spirit.** Denied proposals stay logged with `status='denied'` and zero effect. Both sides read the identical ledger.

## Stack

- **Frontend:** React + Vite + TypeScript + Tailwind. SPA, role-based routing.
- **Backend:** Supabase — Postgres + Auth + RLS + Realtime. Client via `@supabase/supabase-js`.
- **Hosting:** Cloudflare Pages (deploy to a subdomain, e.g. `vault.highendluxuries.com`).
- **Live updates:** Supabase Realtime subscriptions on `movements`, `pieces`, `listings`, `reservations`. This is the "every unit is live" Airtable feel.

## Database

Schema lives in `/supabase/schema.sql`. Run it in the Supabase SQL editor. Key objects:

- Tables: `profiles`, `reseller_settings`, `client_access`, `pieces`, `consignments`, `listings`, `listing_visibility`, `movements`, `reservations`.
- RPCs: `get_my_catalog(slug)`, `propose_movement(...)`, `resolve_movement(id, approve)`.
- View: `reseller_balances` (pieces on consignment, value, net owed to store).

Always go through the RPCs for catalog reads and stock movements. Test RLS with a non-admin token before shipping any new table.

## Design language

Monochrome editorial luxury. Treat inventory like an auction catalogue, not a webshop. No bright accents.

```
--ink:#0A0A0A   --paper:#FAFAF8   --panel:#FFFFFF
--hair:#E4E2DC  --hair-strong:#C9C6BE
--muted:#8C887F --muted-2:#6A675F
--gold:#9A7B3F  (use sparingly, for owed/margin only)
--green:#3E6B4F (settled)  --red:#9A3B33 (denied)
```

- Display / piece names / numerals: **Cormorant Garamond**.
- UI, labels, data: **Inter**. Labels are uppercase, letterspaced (.16em+).
- Hairline rules, generous negative space, zero-radius or near-zero. Status as small letterspaced caps, not coloured pills unless meaningful.
- The visual prototypes in `/prototypes` are the reference for look and interaction. Match them.

## Conventions

- TypeScript everywhere. Generate DB types with `supabase gen types typescript`.
- Keep secrets in `.env` (Supabase URL + anon key on the client; service role only in server-side functions, never shipped to the browser).
- Money stored as numeric, formatted client-side. No floats for cents if it grows.
- Copy: plain, active voice, sentence case. No em dashes.
