-- Mensagem específica pro handoff que sai de "nenhum dia/horário serve" — diferente do
-- handoff genérico, já avisa que a equipe vai ver se consegue encaixar.
insert into whatsapp_ura_settings (key, value) values
  ('handoff_no_slot_message', 'Vou chamar a equipe pra ver se consegue te encaixar 🙂 Só um instante!')
on conflict (key) do nothing;
