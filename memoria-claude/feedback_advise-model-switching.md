---
name: advise-model-switching
description: Gabriel wants me to proactively tell him when to switch Claude models (lighter vs stronger) based on task complexity
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 7a32035e-e902-4e87-9acc-5ce31e0950b8
  modified: 2026-07-24T20:07:56.017Z
---

Gabriel asked me to proactively advise him when to switch models for best performance/quota balance on the prime-barbearia project.

**Why:** His plan has shared session/weekly limits; heavier models burn quota faster. He doesn't want to guess when each is worth it.

**How to apply:** At the start of a task (or when he asks "bora p X"), assess complexity and say which model fits: lighter model (Sonnet) for CSS tweaks, copy changes, small fixes; stronger model (Fable/Opus) for complex features (e.g. Prime Club achievements system), hard-to-find bugs, or large refactors in the single 2700+ line index_9.html. If he's already on the right model, say nothing or confirm briefly. Related: [[push-periodically]].

**Confirmed 2026-07-24 — mechanism clarified:** Gabriel confirmed he wants this to keep happening for the conciliação financeira / contas a pagar work specifically (flagged as likely Sonnet-sufficient overall, with Opus only worth it for the Pix fuzzy-matching logic or an inconsistent extrato parser if those turn out gnarly). Important limitation to state plainly when this comes up: I cannot switch the model myself — I can only recommend it, Gabriel has to actually make the switch in the app/CLI. Also can't always catch complexity in advance — sometimes a task looks simple and only reveals its difficulty mid-way; when that happens, flag it as soon as it's noticed rather than only at the start.
