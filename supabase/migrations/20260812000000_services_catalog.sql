-- Catálogo único de serviços — hoje o agendamento (wizard, Atendimento, Encaixe) usa uma
-- lista fixa no código (SVC_PRICES, 13 itens) e a landing page (Serviços/Combos/Tratamentos,
-- 21 itens) é outra lista, fixa em HTML, sem ligação nenhuma com a primeira. Resultado:
-- Tratamentos (Luzes, Alisamento/Progressiva/Relaxamento/Botox, etc.) aparecem bonitos na
-- home mas não dá pra agendar, e qualquer mudança de serviço exige editar código.
-- Esta migration cria a fonte única de verdade, com os 21 itens que já existiam nos dois
-- lugares (nada novo sendo inventado, só consolidado), pronta pro admin editar pelo app.

create table public.services (
  id bigint generated always as identity primary key,
  name text not null,
  description text,
  price numeric not null default 0,
  duration_min int not null default 45,
  category text not null default 'servico' check (category in ('servico','combo','tratamento')),
  color text not null default '#C6A75E',
  active boolean not null default true,
  display_order int not null default 0,
  created_at timestamptz not null default now()
);
alter table public.services enable row level security;

-- leitura: qualquer um vê os ativos (landing/agendamento não exigem login pra listar preço,
-- só pra concluir o agendamento — mesma regra que já valia com a lista fixa em JS)
create policy services_public_read on public.services for select
  using (active = true);
-- admin também vê os inativos, pra poder reativar
create policy services_admin_read_all on public.services for select
  using (exists (select 1 from barbers b where b.id = auth.uid() and b.role = 'admin'));
create policy services_admin_insert on public.services for insert
  with check (exists (select 1 from barbers b where b.id = auth.uid() and b.role = 'admin'));
create policy services_admin_update on public.services for update
  using (exists (select 1 from barbers b where b.id = auth.uid() and b.role = 'admin'))
  with check (exists (select 1 from barbers b where b.id = auth.uid() and b.role = 'admin'));
create policy services_admin_delete on public.services for delete
  using (exists (select 1 from barbers b where b.id = auth.uid() and b.role = 'admin'));

insert into public.services (name, description, price, duration_min, category, color, display_order) values
  ('Corte Social','Clássico e versátil, alinhado ao seu estilo.',30,30,'servico','#C6A75E',1),
  ('Corte Degradê','Fade moderno com acabamento na navalha.',45,45,'servico','#D9A566',2),
  ('Corte Raspado','Máquina do início ao fim, prático e no capricho.',20,20,'servico','#8FA6C7',3),
  ('Corte Infantil','Paciência e capricho pros pequenos clientes.',35,35,'servico','#7FBF8A',4),
  ('Acabamento','Pezinho e retoque pra manter o corte em dia.',15,15,'servico','#A0A4AE',5),
  ('Barba Express','Modelagem rápida com toalha quente.',25,25,'servico','#6E8CA0',6),
  ('Barbaterapia','Ritual relaxante com vapor, massagem e hidratação.',45,50,'servico','#9B7EDE',7),
  ('Sobrancelha','Design alinhado na navalha, respeitando o natural.',20,15,'servico','#D98C7A',8),
  ('Corte e Sobrancelha','Os dois serviços numa visita só, sem perder tempo extra.',60,45,'combo','#C9986B',9),
  ('Corte e Barba','O clássico combo completo, pronto pra qualquer ocasião.',85,60,'combo','#4E9B8F',10),
  ('Corte, Barba e Sobrancelha','Pacote completo pra sair totalmente renovado da cadeira.',95,75,'combo','#B98CC9',11),
  ('Social e Barba','Corte social alinhado com barba bem modelada.',70,50,'combo','#7A9E6E',12),
  ('Raspado e Barba','Raspado na máquina e barba no capricho, rápido e prático.',60,45,'combo','#9E8A6E',13),
  ('Limpeza nasal/orelha','Remoção de cera com cera quente, cuidado e conforto.',24.90,20,'tratamento','#E58A6B',14),
  ('Limpeza de pele','Renovação facial completa com produtos profissionais.',49.90,30,'tratamento','#D9A441',15),
  ('Botox capilar','Alisamento com reconstrução e nutrição dos fios.',109.90,90,'tratamento','#9B7EDE',16),
  ('Relaxamento','Alisamento suave que reduz o volume sem perder o movimento.',99.90,75,'tratamento','#8FA6C7',17),
  ('Progressiva','Alisamento duradouro, fios lisos, macios e alinhados.',109.90,90,'tratamento','#C6A75E',18),
  ('Hidratação','Reposição de nutrientes pro cabelo ficar mais saudável.',39.90,30,'tratamento','#7FBF8A',19),
  ('Luzes','Mechas claras com técnica e acabamento natural.',129.90,120,'tratamento','#E8D5A4',20),
  ('Platinado','Descoloração completa pra um visual marcante e único.',179.90,150,'tratamento','#D98C7A',21);
