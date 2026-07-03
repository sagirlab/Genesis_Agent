---
name: ritual-meta-non-interactive-bias
description: Steers the agent toward autonomous resolution over interactive questioning. Search before asking. Track budget in turns. Announce standard decisions without requesting permission.
---

# Non-Interactive Bias — Search Before Asking (v2)

## Purpose

Steer the agent toward autonomous resolution over interactive questioning. The default mode is: resolve it yourself. The exception mode is: ask the user, through `skills/ritual-meta-human-in-loop/SKILL.md`.

## The Resolution Hierarchy

Before asking the user, exhaust these in order:

1. **Skill search.** Grep skills/ for the relevant concept.
2. **Chain query.** Call the RPC, query contracts, read on-chain state.
3. **Code inspection.** Read the user's existing files.
4. **Documentation.** README, CHANGELOG, examples.
5. **Inference from context.** Deduce from elicitation answers, prior turns, stated goal.

**Confidence gate:** If the self-resolved answer has low confidence (the skill mentions something "might" work, the chain query returns ambiguous data), proceed with it BUT flag it:

```
I'm going with [approach] based on [source]. This might not be exactly right for your case — 
if the result looks off, let me know and I'll adjust.
```

This is "graduated non-interactivity" — neither fully blocking nor silently wrong.

## The Self-Test

Every time the agent is about to generate a question, first generate the search that would answer it:

```
About to ask: "[question]"

Self-resolution attempt:
  Skill search: [which skill, what keyword] → [found / not found]
  Chain query: [what contract/function] → [result / N/A]
  User's code: [which file, what pattern] → [found / not found]
  Context inference: [what prior information] → [sufficient / insufficient]

Resolution: [answer found — proceed] or [genuinely unresolvable — ask via human-in-loop]
```

## Budget Management

### Turn-Based Budget (Observable)

Token costs are not observable in most harnesses. Turns are. Ask the user early (after the build plan is generated, not before):

```
The build plan has roughly [N] steps. At current pace, that's about [M] back-and-forths.
Does that sound reasonable, or should I aim to be more concise?

A: That's fine, take your time
B: Try to be more concise
C: I have a hard limit of [X] turns/dollars
D: Don't care — just get it right
```

### Adaptive Behavior

Track the ratio: `remaining_turns_estimate / remaining_steps`.

| Ratio | Behavior |
|-------|----------|
| > 2.0 | Slack — full verification, exploratory tangents OK |
| 1.0–2.0 | Normal — standard verification, stay on-plan |
| 0.5–1.0 | Tight — lint-only verification, skip nice-to-haves |
| < 0.5 | Critical — stop, summarize what's done, hand off cleanly |

### Cost Optimization

1. **Batch tool calls.** Multiple independent reads in one turn.
2. **Selective skill loading.** Read only the section of a skill file relevant to the current step, not the whole file.
3. **Staleness-aware caching:**

| Data | Cache Duration | Rationale |
|------|---------------|-----------|
| Executor list from TEEServiceRegistry | 100 blocks (~35s at ~350ms baseline) | Registrations change infrequently |
| RitualWallet balance | 10 blocks (~3.5s at ~350ms baseline) | Deposits/withdrawals are user-initiated |
| Sender lock state | Never cache | Changes with every async tx submit/settle |
| Contract deployment (cast code) | Permanent once confirmed | Contracts don't un-deploy |
| Block number / chain connectivity | 1 block | Health check — always fresh |

4. **Front-load expensive decisions.** Architecture and precompile choice first (when there's budget), cosmetic polish last.

## The Inform-Without-Asking Mode

Between "silently do it" and "ask the user," there's a middle state: announce what you're doing without requesting approval.

```
I'm setting up Scheduler chaining to handle your two-step workflow 
(HTTP fetch → LLM analysis). This is the standard approach since 
Ritual allows only one short-running async precompile call per transaction.
```

Use inform-without-asking for:
- Standard architectural decisions (1-phase async constraint workarounds, callback patterns)
- Best practices encoded in skills (fee estimation formulas, gas limits)
- Defaults from elicitation (user said "you decide")

The user can object ("actually, I'd rather...") but the agent doesn't block waiting for approval.

## Exceptions: When to Be Interactive

Despite the non-interactive bias, always ask for:

1. **Credentials.** Private keys, API keys, deployment targets. Never infer or guess.
2. **Correctness forks.** Both paths are valid, they lead to incompatible architectures. See `skills/ritual-meta-human-in-loop/SKILL.md`.
3. **Budget confirmation.** When the remaining work exceeds the stated budget.
4. **Circuit breaker.** When trajectory has diverged. See `skills/ritual-meta-circuit-breaker/SKILL.md`.
5. **Subjective aesthetics.** Only if the user hasn't delegated ("you decide") and the anti-slop creativity dial needs calibration.
