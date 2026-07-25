---
name: feedback-confirm-understanding
description: "When user asks \"me entende?\" (do you understand me?), paraphrase their request back before proceeding; also avoid deferring work to \"depois\" (later) — execute immediately."
metadata: 
  node_type: memory
  type: feedback
  originSessionId: e4aceed9-df8e-4615-bcd8-2eef10034aa5
---

Whenever the user asks something like "me entende?" ("do you understand me?"), do NOT just say yes/confirm — restate in your own words what they asked for, then let them confirm or correct before proceeding.

Also: don't defer tasks with "vamos fazer isso depois" (let's do that later) — the user wants things executed right away, not queued for a future turn. Move fast and implement immediately.

**Why:** User explicitly asked for this working style on 2026-07-04 while iterating quickly on a demo site (Prime Barbearia), to avoid back-and-forth friction and misunderstandings piling up.

**How to apply:** In this project (and likely others with this user), prioritize speed of execution over caution/deferral. When a request is genuinely ambiguous, don't silently guess AND don't just punt to "later" — either ask a quick clarifying question or make a reasonable call and implement now. When the literal phrase "me entende?" appears, always paraphrase-then-confirm before coding.
