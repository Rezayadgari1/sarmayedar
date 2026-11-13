# Secure game server setup

This repository contains the first server-authoritative backend migration for the Capital game.

## Apply the database migration

1. Open the Supabase project dashboard for project `xtfeisnshjfgrhljplyd`.
2. Open SQL Editor.
3. Create a new query.
4. Paste and run `supabase/migrations/202611130001_secure_game_server.sql`.
5. In Authentication > Sign In / Providers, enable Anonymous Sign-Ins.
6. Do not expose the service-role key in the app or repository.

## Server API

Authenticated clients call these Postgres RPC functions:
- `create_capital_room(display_name)`
- `join_capital_room(code, display_name)`
- `get_capital_room(code)`
- `perform_capital_action(code, action)`

The database owns room membership, turns, dice, rent, tax, chance cards, property purchases and state versioning. Direct client writes to room tables are revoked. RLS limits room reads to members.

## Important rollout status

This is the database backend foundation. The current Android/web client still uses the old Realtime broadcast flow until the client migration is completed. Do not publish the app as secure until the client uses the RPC API, auth persistence and server state subscription, and the migration has been applied and tested in the Supabase project.
