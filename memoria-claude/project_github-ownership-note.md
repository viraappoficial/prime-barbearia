---
name: project-github-ownership-note
description: "prime-barbearia repo foi transferido de gabrielparcel-byte para viraappoficial em 2026-08-01 pra contornar um bug de permissão de push."
metadata:
  node_type: memory
  type: project
  modified: 2026-08-01T00:00:00.000Z
---

**O que aconteceu (2026-08-01):** a integração GitHub da Claude Code neste workspace ficou travada com `403 Resource not accessible by integration` ao tentar dar push no repo `gabrielparcel-byte/prime-barbearia`, mesmo depois de: adicionar `viraappoficial` (conta de automação da Claude Code, também usada no projeto Vira) como colaborador com Write, reconectar o conector GitHub em claude.ai/settings/connectors, e ajustar "Workflow permissions" do repo pra Read+Write. Nenhuma dessas correções resolveu — cada ajuste também só é reconhecido numa sessão **nova** (sessões em andamento ficam com o token/escopo fixado no início).

**Solução aplicada:** Gabriel transferiu a propriedade do repositório de `gabrielparcel-byte` para `viraappoficial` (a própria conta da automação). Como dono, o acesso de escrita passou a funcionar imediatamente — inclusive na sessão que já estava aberta, via redirecionamento automático do Git (`remote: This repository moved...`).

**Estado atual:** o repositório vive em `github.com/viraappoficial/prime-barbearia` (antes era `gabrielparcel-byte/prime-barbearia`). URLs antigas devem redirecionar automaticamente, mas ao configurar integrações novas (Vercel, Supabase-GitHub, etc.) usar o novo caminho. `gabrielparcel-byte` deixou de ser dono do repo.
