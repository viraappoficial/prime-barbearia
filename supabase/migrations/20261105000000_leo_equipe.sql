-- Léo da equipe: assistente de consulta no app. Só lê. O consumo de IA fica registrado aqui (a tela "IA" da Gestão pode somar depois).
-- Só a Edge Function (service_role) grava e lê; ninguém mais.
create table if not exists public.leo_equipe_uso (
  id bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  user_id uuid not null,
  dia date not null,
  tipo text not null check (tipo in ('atalho', 'ia')),
  modelo text,
  entrada_tokens integer not null default 0,
  saida_tokens integer not null default 0,
  cache_leitura_tokens integer not null default 0,
  cache_escrita_tokens integer not null default 0,
  chamadas integer not null default 0,
  custo_usd numeric(10,6) not null default 0
);
create index if not exists leo_equipe_uso_dia_user on public.leo_equipe_uso (dia, user_id);
create index if not exists leo_equipe_uso_created on public.leo_equipe_uso (created_at);
alter table public.leo_equipe_uso enable row level security;
revoke all on public.leo_equipe_uso from anon, authenticated;

-- Limites (editáveis em whatsapp_ura_settings): perguntas livres por pessoa por dia e teto de gasto do mês (US$). Estourou o teto, só os atalhos (sem IA) continuam.
insert into public.whatsapp_ura_settings (key, value) values
  ('leo_equipe_ligado', 'true'),
  ('leo_equipe_limite_dia', '30'),
  ('leo_equipe_teto_mes_usd', '10')
on conflict (key) do nothing;
