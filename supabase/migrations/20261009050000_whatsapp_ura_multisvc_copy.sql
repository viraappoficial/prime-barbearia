-- Multi-seleção de serviço ("1,6" ou "1 e 6") — troca a coluna de id único pro array.
alter table public.whatsapp_ura_sessions drop column if exists service_id;
alter table public.whatsapp_ura_sessions add column if not exists service_ids bigint[];

-- Reescrita das mensagens da URA — mais conversacional, menos robótica (revisão de copy, não
-- muda nenhuma lógica). on conflict do update porque as chaves já existem desde a seed
-- original; isso aqui SUBSTITUI o texto que já está lá (inclusive se alguém já editou pela
-- tela do ViraDeck — é intencional, é essa revisão que está sendo aplicada agora).
insert into whatsapp_ura_settings (key, value) values
  ('menu_option_agendar', 'Quero agendar um horário ✂️'),
  ('menu_option_meus_agendamentos', 'Ver meus agendamentos 📅'),
  ('menu_option_servicos', 'Nossos serviços e preços 💈'),
  ('menu_option_endereco', 'Endereço e horário 📍'),
  ('menu_option_atendente', 'Falar com a equipe 🙋'),
  ('menu_message_known', 'Oi, {nome}! Tudo bem? 😊 Que bom te ver por aqui de novo.'),
  ('menu_message_new', 'Oi! Seja bem-vindo à Prime Barbearia 💈 Não achei seu cadastro aqui ainda — é sua primeira vez com a gente?'),
  ('ask_service', 'Show! Esses são nossos serviços 👇'),
  ('ask_barber', 'Com qual barbeiro você prefere?'),
  ('ask_day', 'Qual dia fica melhor pra você?'),
  ('ask_time', e'Esses horários tão livres nesse dia 👇'),
  ('confirm_summary_template', e'Fechando então:\n✂️ {servicos} com {barbeiro}\n📅 {dia} às {hora}'),
  ('confirm_success', 'Prontinho! ✅ Te espero {dia} às {hora}. Até lá! 💈'),
  ('fallback_message', 'Opa, não entendi 🤔 Escolhe uma das opções:'),
  ('handoff_message', 'Só um segundinho que já chamo alguém da equipe pra te atender por aqui 🙋')
on conflict (key) do update set value = excluded.value, updated_at = now();
