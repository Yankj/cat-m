-- catpaw.connectors.gmail.v1 (v1.1). WRITTEN ONLY — NOT APPLIED (apply needs the user's approval).
-- One row per (owner, provider). Refresh token is AES-256-GCM encrypted in the Edge function with CATPAW_CONNECTOR_TOKEN_KEY;
-- the DB never sees plaintext. account_epoch binds the row to the AccountEpoch it was linked under; a different epoch ⇒ parked.
create schema if not exists connectors;
revoke all on schema connectors from public, anon, authenticated;
create table connectors.links (
  owner uuid not null references auth.users(id) on delete cascade,
  provider text not null check (provider in ('gmail')),
  account_epoch bigint not null check (account_epoch >= 0),
  state text not null default 'active' check (state in ('active','parked','revoked')),
  scopes text[] not null check (scopes <@ array['https://www.googleapis.com/auth/gmail.readonly','openid','email']),
  disclosure_version text not null,
  token_ciphertext bytea not null,
  token_nonce bytea not null check (octet_length(token_nonce) = 12),
  history_id text,
  last_polled_at timestamptz,
  created_at timestamptz not null default now(),
  primary key (owner, provider)
);
create table connectors.seen_items (
  owner uuid not null references auth.users(id) on delete cascade,
  dedupe_key text not null check (char_length(dedupe_key) <= 400),
  message_id text not null,
  sequence integer not null default 0,
  created_at timestamptz not null default now(),
  primary key (owner, dedupe_key)
);
alter table connectors.links enable row level security;
alter table connectors.seen_items enable row level security;
-- No policies: only the service role (Edge function) reads/writes.
