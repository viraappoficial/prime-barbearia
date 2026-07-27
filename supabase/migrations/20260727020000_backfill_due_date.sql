-- Despesas lançadas antes da coluna due_date existir ficam sem vencimento e
-- desapareceriam da tela de Contas a Pagar (que filtra por due_date). Usa a
-- própria data de lançamento como vencimento nesses casos legados.
update public.expenses set due_date = date where due_date is null;
