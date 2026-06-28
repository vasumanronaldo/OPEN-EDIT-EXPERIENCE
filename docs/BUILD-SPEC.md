# Build Spec — Edit Experience Platform

The plan Claude Code builds against. Read `CLAUDE.md` first for invariants and stack.

## Decisions locked

- Admin issues **reseller accounts only**. Resellers invite and manage their own B2B clients, inside admin-set rules.
- Reseller rules (per account, set at creation): client cap, price floor / min margin, approval threshold for high-value pieces, whether they can expose store stock.
- A client can be keyed into **multiple resellers** and switch between them.
- Every stock change is **two-party approved**. Shared Splitwise-style ledger tracks movements and net owed to store.
- **Settlement is a deliberate two-party step** (store confirms payment received as a `settled` movement). Not auto-cleared.
- **A denied proposal is killed, not edited.** The proposer re-proposes fresh if they want to counter. Keep it simple in v1; a counter-offer thread can come later.

## Phased roadmap

**Phase 0 — Foundations**
- Init Vite + React + TS + Tailwind. Set up Supabase project. Run `schema.sql`.
- Seed one admin profile by hand. Wire `supabase-js` client and `.env`.
- Confirm RLS: log in as a seeded reseller, confirm they cannot read another reseller's pieces.

**Phase 1 — Auth and shells**
- Supabase Auth (email or magic link). On login, read `profiles.role`, route to the right portal.
- Three empty portal shells (admin / reseller / client) matching the design language.

**Phase 2 — Admin: the vault**
- Master inventory table: create / edit pieces (brand, model, ref, condition, cost, consigner, status).
- Issue reseller accounts: create the auth user + profile + `reseller_settings`.
- Assign store stock to a reseller (creates a `consignment` with agreed price) via `propose_movement` type `added`.
- Accounts and access view + the access matrix.

**Phase 3 — Reseller: my edit, my clients**
- My inventory: own pieces + consigned store stock. Create `listings` (set client price, enforce floor from settings).
- My clients: invite flow that generates `access_key` + `link_slug`, enforces `client_cap`, sets scope (full / curated). Curated builds `listing_visibility` rows.
- Copy private link button.

**Phase 4 — Client: private viewing**
- Login by key / link → resolve `client_access` → render catalogue via `get_my_catalog(slug)`.
- Reseller switcher for clients keyed to more than one.
- Reserve / enquire → insert `reservations`.

**Phase 5 — The ledger (two-way)**
- Pending approvals inbox: items where `counterparty_id = me`. Approve / deny calls `resolve_movement`.
- Shared ledger table from `movements`, running balance from `reseller_balances`.
- Wire Realtime so a proposal or approval shows live on both sides.

**Phase 6 — Harden and ship**
- Revoke / expire client keys. Audit completeness. Empty and error states.
- Mobile pass. Keyboard focus. Reduced motion.
- Deploy to Cloudflare Pages on a subdomain. Point DNS.

## Kickoff prompt for Claude Code

Paste this to start:

> I'm building the Edit Experience inventory platform. Read CLAUDE.md and docs/BUILD-SPEC.md fully before doing anything, then confirm you understand the four invariants back to me in one line each.
>
> Start Phase 0 and Phase 1. Scaffold a Vite + React + TypeScript + Tailwind SPA. Set up the Supabase client from env vars. Build Supabase Auth with role-based routing that reads profiles.role and sends admin, reseller, and client to three separate portal shells styled to the design tokens in CLAUDE.md. Do not build any inventory features yet. When the shells render and auth routing works, stop and show me how to seed an admin so I can log in.
>
> Assume schema.sql is already run in Supabase. Never write to the movements table or change pieces.status directly; always use the RPCs. Never expose cost or basis to a client.
