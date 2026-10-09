-- Telefones dos barbeiros (só dígitos, com 55). Confira o resultado do select no fim.
update public.barbers set phone = '554491781304' where lower(name) like 'nathan%';
update public.barbers set phone = '554497386172' where lower(name) like 'miguel%';
select id, name, role, phone from public.barbers order by name;
