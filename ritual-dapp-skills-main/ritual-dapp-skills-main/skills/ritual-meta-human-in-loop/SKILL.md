---
name: ritual-meta-human-in-loop
description: Defines when and how to pull the user for a decision mid-session. Only at architectural forks that are expensive to switch and not resolvable by search.
---

# Human-in-Loop — Mid-Session Elicitation (v2)

## Purpose

Define when and how to pull the user for a decision during an active build/debug session. The constraint: only interrupt when the decision would fork the trajectory into branches that are expensive to switch between, and only when the answer isn't discoverable by the agent itself.

## The Fork Test (Revised)

Before asking the user anything mid-session:

1. **Is there a fork?** Does the next step have 2+ valid approaches?
2. **Was this resolved by initial elicitation?** Check whether any elicitation answer already determines this fork. If yes, use that answer — don't re-ask.
3. **Is it a correctness fork or a preference fork?**
   - *Correctness:* One branch is technically impossible or will fail. Always pull — regardless of budget.
   - *Preference:* Both branches work, the user just might prefer one. Respect the pull budget.
4. **Can I resolve it myself?** Search skills, check chain state, review existing code. If the answer is findable, find it.
5. **Is the switch cost high?** Would choosing wrong require rewriting >1 file or redeploying?

**Pull the user if:** (1) AND NOT (2) AND (preference AND budget remaining, OR correctness) AND NOT (4) AND (5).

## Canonical Fork Points

Static forks known to Ritual dApp development:

| Fork | Type | Branch A | Branch B | Switch Cost |
|------|------|----------|----------|-------------|
| Short-running vs long-running | Correctness | Inline receipt result | Callback to contract | Contract redesign |
| Direct call vs consumer contract | Preference | EOA → precompile | Contract wraps precompile | Architecture change |
| Owner secrets vs delegated | Preference | User encrypts per-request | ACL-based delegation | Encryption flow rewrite |
| Persistent memory vs one-shot agent | Correctness | Sovereign Agent (0x080C) or LLM-only (no 0x0820) | Persistent Agent (0x0820) | Completely different ABI |
| SSE streaming vs receipt polling | Preference | Real-time tokens via fetch()+SSE with auth headers | Poll spcCalls after settlement | Frontend architecture |
| Passkey vs wallet auth | Preference | TxPasskey (0x77), P-256 | MetaMask, secp256k1 | Tx type, address derivation |

**General fork detection heuristic for novel forks:** "Am I about to write code that hard-codes assumption X, where the user might reasonably want Y, and switching X→Y after deployment requires more than local edits?" If yes, it's a fork.

## How to Pull

### Format

Present 2-3 options (never more) with a recommendation:

```
I've reached a design decision:

[One-sentence description of what forks]

A: [First option — one sentence, plain language]
B: [Second option — one sentence, plain language]

I'd go with [A/B] because [one concrete reason].

Should I proceed with that, or do you prefer the other?
```

### Correctness Forks

For correctness forks, frame it as a constraint, not a choice:

```
Your design needs [X], but [constraint Y] prevents it.

Two ways to handle this:
A: [Workaround one]
B: [Workaround two — fundamentally different]

I'd recommend A because [reason]. Should I go with that?
```

### Timeout

If the user doesn't respond within 2 turns, proceed with the recommendation. Note: "Went with [option] — let me know if you'd like to change direction."

## Pull Budget

The budget is derived from the build plan, not a constant:

1. After elicitation, count the number of unresolved forks in the build plan.
2. Set the pull budget = number of unresolved forks.
3. Correctness forks don't count against the budget — they always fire.

After exhausting the budget, default to recommendations silently for preference forks. Log the decision for traceability.

## Within-Session Learning

Track the user's decision pattern:

- If the user picked the simpler option 2+ times → bias future recommendations toward simplicity.
- If the user overrode the recommendation 2+ times → increase pull frequency (the agent's model is miscalibrated).
- If the user said "you decide" 2+ times → reduce pull frequency (the user is delegating).

This learning resets at session boundaries — don't carry preferences across sessions unless the user explicitly says to.

## Relationship to Other Omega Skills

| Skill | Relationship |
|-------|-------------|
| `skills/ritual-meta-elicitation/SKILL.md` | Handles session-start. Human-in-loop handles mid-session. Check elicitation answers before pulling. |
| `skills/ritual-meta-non-interactive-bias/SKILL.md` | Says "search before asking." Human-in-loop is the exception for preference-based forks that search can't resolve. |
| `skills/ritual-meta-circuit-breaker/SKILL.md` | Fires when trajectory diverges. Human-in-loop prevents divergence by catching forks before they become problems. |
| `skills/ritual-meta-orchestrator/SKILL.md` | Defines the α/β interleave. Human-in-loop triggers during α when a fork is detected. |
