---
name: ritual-meta-elicitation
description: Lazy goal-state variance reduction. Generates 0-5 contextual questions just-in-time based on the user's stated goal. Never presents a static questionnaire.
---

# Elicitation — Lazy Goal-State Variance Reduction (v3)

## Purpose

Compress uncertainty about the user's goal state through a bounded, dynamically generated questionnaire. Questions are not predetermined — they are synthesized just-in-time, conditioned on the user's initial description. Each question targets the highest-uncertainty dimension remaining for THIS specific goal.

## Why Lazy, Not Eager

v2 used 10 static questions covering the entire Ritual feature space. Problems:

1. **Most questions are irrelevant.** A user building a chatbot doesn't need questions about ZK proofs, multimodal generation, or scheduling. Static questions waste turns on dimensions that the user's description already resolves.
2. **Options can't be contextualized.** Static option (A) says "Answer questions or generate text." But if the user said "I want a chatbot that remembers conversations," the real question isn't "do you want LLM?" (obviously yes) — it's "should memory use Persistent Agent (0x0820), Sovereign Agent (0x080C) for autonomous tool use, or LLM (0x0802) with app-managed history?" Static questions can't ask this because they don't know the context.
3. **The uncertainty distribution is non-uniform.** For a given user goal, some dimensions are fully determined (no uncertainty), some are slightly ambiguous (low uncertainty), and some are completely open (high uncertainty). Static questions waste equal time on all dimensions. Lazy questions target only the high-uncertainty ones.

## The Protocol

### Step 1: Parse the User's Initial Message

Extract what IS known from the user's first message. Map to Ritual concepts:

```
User says: "Build me a chatbot that remembers conversations and can search the web"

Extracted signals:
  - "chatbot" → LLM precompile (0x0802) — HIGH confidence
  - "remembers conversations" → Persistent Agent (0x0820) — MEDIUM confidence (could also be LLM + frontend state)
  - "search the web" → HTTP precompile (0x0801) or Agent tools — MEDIUM confidence
  - Frontend: UNKNOWN (not mentioned)
  - Authentication: UNKNOWN (not mentioned)
  - Privacy: UNKNOWN (not mentioned)
  - Scheduling: UNLIKELY (no temporal language)
  - Fee model: UNKNOWN (not mentioned)
```

### Step 2: Identify the Top-K Unresolved Dimensions

Rank all dimensions by remaining uncertainty for THIS goal. A dimension is "resolved" if the user's message determines it with high confidence. A dimension is "unresolved" if the user's message is ambiguous or silent about it.

**Dimension universe** (the full set of architectural decisions for a Ritual dApp):

| Dimension | What it determines |
|-----------|-------------------|
| Primary precompile | Which precompile to call, which skill to load |
| Execution model | Short-running (inline result) vs long-running (callback) |
| Statefulness | Stateless per-request vs persistent across sessions |
| Frontend needs | Full web app vs minimal vs none |
| Authentication | Wallet vs passkey vs backend signer vs none |
| Privacy model | Public vs encrypted inputs vs encrypted outputs vs FHE |
| Multi-operation | Single precompile per action vs chained operations |
| Scheduling | Manual trigger vs recurring vs event-driven |
| External APIs | Authenticated (secrets needed) vs public |
| Monetization | Free vs pay-per-call vs subscription |
| Data persistence | Ephemeral vs backend indexed vs on-chain |
| Target environment | Greenfield vs augmenting existing project |

For the chatbot example, after parsing:
- Primary precompile: RESOLVED (LLM / agent precompiles — high confidence)
- Statefulness: PARTIALLY RESOLVED (mentions "remembers" — needs one question to disambiguate)
- Multi-operation: PARTIALLY RESOLVED ("search the web" implies chaining — needs one question)
- Frontend, Auth, Privacy, Scheduling, Monetization, Persistence, Environment: UNRESOLVED

Select the **top 3-5 unresolved dimensions** by impact (how much the answer changes the architecture).

### Step 3: Generate Questions Just-In-Time

For each unresolved dimension, generate a question with 4 contextual options + "you decide." The options must be specific to THIS user's goal, not generic.

**Generation template:**

```
For the dimension: [dimension name]
Given the user wants: [one-sentence goal summary]
The architectural fork is: [what changes depending on the answer]

Generate:
  Question: [one sentence, plain language, no jargon]
  Option A: [concrete choice, contextualized to their goal]
  Option B: [concrete choice, different from A]
  Option C: [concrete choice, different from A and B]
  Option D: [concrete choice, different from all above]
  Option E: "Not sure — you decide"
```

**Example for the chatbot:**

```
Dimension: Statefulness
Goal: Chatbot that remembers conversations and searches the web

Q1: How should the chatbot remember past conversations?

  A: It remembers everything permanently — long-term memory across all sessions
     → Persistent Agent (0x0820) with MEMORY.md reference
  B: It remembers within a single session but starts fresh each time
     → LLM (0x0802) with frontend-managed message history
  C: It remembers the last N messages only (sliding window)
     → LLM (0x0802) with truncated context window
  D: No memory needed — each question is independent
     → LLM (0x0802) stateless
  E: Not sure — you decide
```

```
Dimension: Frontend
Goal: Chatbot that remembers conversations and searches the web

Q2: How should users interact with the chatbot?

  A: Full web app with real-time streaming responses (typewriter effect)
     → Next.js + SSE streaming + ritual-dapp-frontend + ritual-dapp-design
  B: Simple page with a text box and a response area
     → Minimal React page, no streaming
  C: API only — I'll build my own frontend or use it programmatically
     → No frontend skill, just the contract + encoding
  D: Embedded widget I can drop into an existing site
     → Standalone component, no full app
  E: Not sure — you decide
```

```
Dimension: Multi-operation
Goal: Chatbot that remembers conversations and searches the web

Q3: How should "search the web" work with the chatbot?

  A: The AI agent handles search internally as a tool — one precompile call does everything
     → Sovereign Agent (0x080C) with web_search tool
  B: Search first (HTTP precompile), then feed results to the AI (LLM precompile) — two steps
     → HTTP (0x0801) → Scheduler chain → LLM (0x0802)
  C: The AI decides when to search — sometimes it answers directly, sometimes it searches first
     → Sovereign Agent (0x080C) with conditional tool use
  D: Search is a separate feature — the user explicitly clicks "search" vs "ask"
     → Two independent flows, no chaining
  E: Not sure — you decide
```

### Step 4: Present and Collect

Present all generated questions at once (not one at a time). Same rules as v2:

1. **Entirely optional.** If the user says "skip" or "just build it," infer from context and proceed.
2. **Confirmation echo.** After answers (or inference), state: "I understood: [goal summary with resolved dimensions]. Is that right?"
3. **"Not sure" defaults.** For any (E) answer, the agent picks the option that minimizes architectural complexity while still satisfying the stated goal.

### Step 5: Map Answers to Skills

Each answer directly determines which skills to load and which architectural pattern to use. This mapping is NOT predetermined — it's derived from the specific options generated in step 3.

## Constraints

- **Maximum 5 questions.** If you need more, your parsing in Step 1 wasn't aggressive enough. Reparse.
- **Minimum 0 questions.** If the user's description is detailed enough to resolve all high-impact dimensions, don't ask anything — just echo back and confirm.
- **No jargon in questions.** The user doesn't know what "short-running async" means or what "long-running async" is. Phrase options in terms of user-visible behavior, not protocol mechanics.
- **Options must be mutually exclusive.** If two options lead to the same architecture, merge them.
- **Each option must name the consequence.** After the user-facing text, include a one-line technical note (→ Persistent Agent, → LLM + Scheduler, etc.) so the agent knows what to do with the answer.

## When the User Provides a Long Spec

If the user's initial message is >200 words and reads like a specification (mentions features, data flows, UI requirements), treat it as if they answered all questions. Run Step 1 parsing aggressively, echo back the inferred decisions, and ask only about genuinely ambiguous dimensions (likely 0-1 questions).

## When the User Says Almost Nothing

If the user says "build me something cool" or "what can Ritual do?", the lazy approach generates nothing — there's not enough signal to form contextual questions. Instead, route to the front door (ritual/SKILL.md) which shows capability teasers and lets the user refine their intent.

## Comparison with v2

| Aspect | v2 (Static/Eager) | v3 (Lazy/JIT) |
|--------|-------------------|---------------|
| Questions | 10 predetermined | 0-5 generated per user |
| Options | Fixed across all users | Contextualized to the user's goal |
| Irrelevant questions | Suppressed by static rules | Never generated in the first place |
| Context sensitivity | None — same form for everyone | Full — questions depend on what the user said |
| Jargon | "What is your primary precompile?" | "How should the chatbot remember conversations?" |
| When it fails | User's goal doesn't fit the 10 questions | User says almost nothing (falls back to front door) |
| Token cost | Fixed (~500 tokens for the form) | Variable (0-300 tokens depending on ambiguity) |

## Implementation Note for the Agent

This is a meta-skill — it tells you HOW to generate questions, not WHAT the questions are. When you load this skill:

1. Do NOT present a static questionnaire.
2. DO parse the user's first message for signals.
3. DO identify the unresolved high-impact dimensions.
4. DO generate 0-5 questions with contextualized options.
5. DO include the technical consequence after each option (for your own routing, not shown to user).
6. DO confirm the understood goal before proceeding.
7. If the user skips, infer the best answers from context and proceed with a confirmation echo.
