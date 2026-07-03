---
name: ritual-meta-inspiration
description: Generates contextual dApp ideas by searching for what's trending in blockchain and AI right now, then filtering for applications that maximally exploit Ritual Chain's unique precompile capabilities. Invoked by the front door when the user doesn't specify what they want to build.
---

# Inspiration — Just-In-Time Idea Generation

## When This Activates

The front door invokes this skill when the user's intent is ambiguous or empty — they want to build something on Ritual but don't know what. Instead of showing a static list of example prompts, this skill generates live, contextual ideas grounded in what's actually happening right now.

## The Protocol

### Step 1: Search for what's trending

Run **three parallel web searches** (use the web search tool). Vary the queries to avoid stale results:

1. `"AI crypto applications [current month] [current year]"` — what's being built right now
2. `"on-chain AI agents use cases new"` — emerging demand signals
3. `"blockchain AI hackathon winners [current year]"` — what's actually getting built and winning

Extract the top 5-8 themes from the combined results. Look for specific signals: project launches, hackathon trends, developer demand, user complaints about existing solutions.

**If web search fails or returns no useful results:** fall back to the static examples in the front door's welcome screen. Do not invent trends. Announce: "I couldn't fetch live trends, so here are proven ideas instead."

### Step 2: Filter through Ritual's unique capabilities

For each theme, ask: **can this be built better on Ritual than anywhere else?** The filter is Ritual's enshrined precompiles — capabilities that exist on-chain natively, not through oracles or off-chain bridges:

| Ritual Capability | Precompile | What It Enables That Other Chains Can't |
|---|---|---|
| On-chain LLM inference | 0x0802 | Smart contracts that think — no oracle, no off-chain API, verifiable by TEE |
| On-chain HTTP calls | 0x0801 | Contracts that fetch live data — prices, APIs, webhooks — inside TEE |
| Autonomous AI agents | 0x0820, 0x080C | Multi-step reasoning agents that run on-chain; persistent memory (0x0820) or sovereign execution (0x080C) |
| On-chain image generation | 0x0818 | AI-generated visual assets with on-chain content hashes |
| On-chain audio generation | 0x0819 | AI-generated audio with verifiable provenance |
| On-chain video generation | 0x081A | AI-generated video with verifiable provenance |
| Scheduled execution | Scheduler | Recurring autonomous operations without off-chain cron |
| Native passkey auth | 0x0100 | WebAuthn login without MetaMask — mainstream UX |
| Secret management | ECIES + ACL | Encrypted API keys and private outputs, on-chain delegation |
| Micropayments | X402 | Pay-per-call API access from smart contracts |

**Hard filter: each surviving theme must map to a specific precompile address (0x08XX) or system contract.** If you can't name the address, the idea doesn't exploit Ritual. Discard it. A generic DEX or lending protocol doesn't belong here — those work the same on any EVM chain.

**Deduplication: discard any idea that overlaps with these static examples** (already shown elsewhere):
- Chatbot / conversational AI (already a default example)
- Price oracle / ETH price feed (already a default example)
- NFT image generation from text (already a default example)
- Scheduled API calls (already a default example)
- AI research agent (already a default example)

The point of this skill is to show the user something they haven't already seen.

### Step 3: Generate 4-5 concrete app ideas

For each surviving theme, generate a specific, buildable application idea. Each idea must include:

1. **One-line pitch** — what the user would say to the builder agent
2. **Why now** — one sentence connecting this idea to something specific from the search results (a trend, a launch, a gap in the market)
3. **Why Ritual** — which specific precompile address(es) make this impossible or impractical on other chains
4. **Complexity** — estimated number of precompiles involved (1 = simple, 3+ = ambitious)

### Step 4: Present to the user

Format the ideas as a numbered list. The user picks one (or describes a variation), and the front door routes to the builder agent with that as the spec.

**Presentation format:**

```
Here are some ideas based on what's trending right now:

1. [One-line pitch]
   Trending because: [why now — one sentence from search results]
   Uses: [precompile addresses]. [Why only Ritual can do this.]

2. [One-line pitch]
   Trending because: [why now]
   Uses: [precompile addresses]. [Why only Ritual.]

3. ...

Pick a number, describe your own twist, or tell me something completely different.
```

## Constraints

- **Always search live.** Never use cached or training-data ideas. The value of this skill is that it reflects what's happening NOW, not what was trending when the skills were written.
- **Maximum 5 ideas.** More than 5 creates decision paralysis.
- **Minimum 3 ideas.** Fewer than 3 doesn't give enough range.
- **Each idea must be buildable in one session.** Don't suggest "build a full autonomous hedge fund" — suggest "build a contract that uses an AI agent to research a token and publish a buy/sell signal."
- **Vary the complexity.** At least one simple idea (1 precompile), at least one ambitious idea (3+ precompiles). The user should see the range of what's possible.
- **No generic blockchain apps.** Every idea must require at least one Ritual-specific precompile. If it could be built on Ethereum with Chainlink, it doesn't belong here.
- **Ground in the search results.** Each idea should connect to something you found trending. Don't invent trends.
