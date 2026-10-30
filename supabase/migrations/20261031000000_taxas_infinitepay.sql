-- Taxas da InfinitePay (plano Receba na Hora) + como o cliente pagou online, para a conciliação.
-- Crédito 1x a 12x e débito valem para todas as bandeiras; o Pix online fica sem taxa até a InfinitePay informar.
alter table public.appointment_payments
  add column if not exists capture_method text,
  add column if not exists installments integer;

alter table public.taxas_maquininha drop constraint if exists taxas_maquininha_forma_check;
alter table public.taxas_maquininha add constraint taxas_maquininha_forma_check
  check (forma = any (array['debito', 'credito', 'pix_qrs', 'pix_online']));

delete from public.taxas_maquininha where forma in ('debito', 'credito');
insert into public.taxas_maquininha (forma, bandeira, parcelas, taxa_pct)
select 'debito', b, 1, 2.29 from unnest(array['Visa', 'Mastercard', 'Elo', 'Amex', 'Outra']) b;
insert into public.taxas_maquininha (forma, bandeira, parcelas, taxa_pct)
select 'credito', b, p.n, p.pct
from unnest(array['Visa', 'Mastercard', 'Elo', 'Amex', 'Outra']) b,
     (values (1, 5.49), (2, 10.89), (3, 11.99), (4, 12.59), (5, 13.29), (6, 13.99), (7, 14.99), (8, 15.59), (9, 16.19), (10, 16.89), (11, 17.89), (12, 18.29)) as p(n, pct);

-- Duas tabelas: 'maquininha' (InfiniteTap, com débito) e 'online' (link do site e do Léo, só crédito e Pix; bandeira 'Todas').
alter table public.taxas_maquininha add column if not exists canal text not null default 'maquininha' check (canal in ('maquininha', 'online'));
insert into public.taxas_maquininha (canal, forma, bandeira, parcelas, taxa_pct)
select 'online', 'credito', 'Todas', p.n, p.pct
from (values (1, 5.49), (2, 10.89), (3, 11.99), (4, 12.59), (5, 13.29), (6, 13.99), (7, 14.99), (8, 15.59), (9, 16.19), (10, 16.89), (11, 17.89), (12, 18.29)) as p(n, pct);
