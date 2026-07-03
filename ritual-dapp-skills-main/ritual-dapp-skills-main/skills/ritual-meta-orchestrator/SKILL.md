---
name: ritual-meta-orchestrator
description: Defines how the agent interleaves build (α) and debug (β) work. Four principles for atomic verification, monotonic progress, phase-aware depth, and context-preserving handoffs.
---

# Orchestrator — Interleaving Build and Debug (v2)

## Purpose

Define when, how, and why an agent switches between building (α-class) and debugging (β-class). The core invariant: build and debug are not phases — they are interleaved at the granularity of every irreversible action.

**Irreversibility test:** If undoing the action requires a new on-chain transaction, a contract redeployment, or would lose user-visible state, the action is irreversible. Verify it before moving on. File writes, config changes, and local edits are reversible and need only lint-level verification.

## The Four Principles

### Principle 1: Atomic Verify

After every irreversible action, run the minimum viable verification before proceeding.

**Trigger conditions by verification depth:**

| Depth | Trigger | Cost | Examples |
|-------|---------|------|----------|
| **Lint** | Every code change | Near zero | Syntax errors, type mismatches, import issues |
| **Simulate** | Any ABI encoding or precompile interaction | Low | `eth_call` against the precompile, local test |
| **Smoke** | Any deployment or on-chain state change | Medium | `cast code`, `cast call`, receipt inspection |
| **E2E** | Completion of a build phase | High | Frontend → contract → precompile → executor → callback → UI |

**Regression gate:** After applying a fix from β-class, re-verify that all previously passing steps still pass. Do not assume a fix is isolated — Ritual's async lifecycle creates coupling between steps that don't appear coupled.

### Principle 2: Monotonic Progress

Every build-debug cycle must advance at least one verified step. If the same error recurs after a structurally different fix, the problem is misdiagnosed — do not retry, re-diagnose.

**Escalation thresholds (class-dependent):**

| Problem Class | Max Retries | Rationale |
|--------------|-------------|-----------|
| Configuration (wrong address, bad chain ID) | 1 | These are lookup errors, not reasoning errors |
| ABI encoding (wrong fields, wrong order) | 2 | Precompile ABIs are complex — one retry is reasonable |
| Architectural (1-phase async constraint, sender lock) | 1 | These require redesign, not retry |
| Integration (callback not firing, receipt missing spcCalls) | 3 | Genuine multi-variable debugging |
| Unknown / novel | 3 | Full diagnostic pipeline needed |

**The tried-list:** Before every retry, check: "Have I tried this exact approach before?" If yes, it must be structurally different. "Different gas limit" is not structurally different. "Different executor" is. "Different callback selector" is.

### Principle 3: Phase-Aware Verification Depth

Match verification depth to the current build phase, not just the individual step.

| Phase | Primary α Skills | Default Verification Depth | Bug Economics |
|-------|-----------------|---------------------------|---------------|
| **Scaffolding** (project setup, config, chain connection) | deploy, overview | Lint + simulate | Bugs are free to fix |
| **Contracts** (Solidity, precompile encoding, callbacks) | contracts, wallet, feature skills | Simulate + smoke | Bugs require redeployment |
| **Frontend** (React, wagmi, state machine, UI) | frontend, design | Lint + browser check | Bugs are annoying but cheap |
| **Integration** (end-to-end, precompile calls, real executors) | all loaded skills | Full E2E | Bugs consume RITUAL and block time |
| **Deployment** (mainnet, DNS, proxy) | deploy | Full E2E + manual checklist | Bugs are visible to users |

**Escalation during integration phase:** Integration bugs that survive 2 cycles get the full β-class diagnostic pipeline (triage → quick-match → smoke → ordered checks). Do not attempt ad-hoc debugging during integration — use the pipeline.

### Principle 4: Context-Preserving Handoffs

When switching between α and β, serialize the relevant context explicitly. In multi-agent systems (Task tool, sub-agents), memory is not shared — you must pass it.

**α → β handoff (build to debug):**
```
{
  lastAction: "Deployed LLMConsumer to 0x...",
  expectedOutcome: "Contract verifiable on explorer, requestInference() callable",
  actualOutcome: "Transaction reverted with 'Stack too deep'",
  filesModified: ["contracts/LLMConsumer.sol"],
  txHash: "0x...",  // if applicable
  buildPhase: "contracts",
  previouslyVerifiedSteps: ["chain connection", "RitualWallet deposit"]
}
```

**β → α handoff (debug to build):**
```
{
  rootCause: "LLM precompile has 26 params — exceeds Solidity stack limit without via_ir",
  fixApplied: "Added via_ir = true to foundry.toml",
  verificationResult: "Contract compiles. eth_call simulation returns expected simmedInput.",
  downstreamChanges: ["Recompile all contracts", "Re-run deployment"],
  regressionRisks: ["Other contracts may need via_ir if they also encode large tuples"]
}
```

**Priority ordering for multi-issue:** When verification reveals multiple issues, fix them in dependency order:
1. Infrastructure issues first (RPC, chain config, executor availability)
2. Contract issues second (deployment, encoding, callbacks)
3. Frontend issues last (rendering, state management, UX)

Within each tier, fix in causal order — the issue that causes or masks other issues goes first.

## The Interleave Loop

```
α: Plan step N
α: Execute step N
β: Verify step N (depth = phase-appropriate)
  ├── PASS
  │   ├── Add to verified-steps list
  │   └── α: Plan step N+1
  └── FAIL
      ├── β: Diagnose (load appropriate β reference files)
      ├── Check tried-list: is this a novel approach?
      │   ├── YES → β: Apply fix → β: Re-verify step N → β: Regression-check verified steps
      │   │         ├── All pass → α: Plan step N+1
      │   │         └── Regression found → β: Diagnose regression (new issue)
      │   └── NO → Increment retry counter
      │             ├── Under threshold → β: Re-diagnose with different hypothesis
      │             └── Over threshold → Invoke circuit-breaker
      └── ESCALATE if root cause not identified after full diagnostic pipeline
```

## When NOT to Interleave

Some α-class work is exploratory and does not benefit from verification:
- Writing comments or documentation
- Refactoring code that hasn't been deployed
- Planning architecture (before any code is written)
- Comparing alternative approaches (before committing to one)

For these, stay in α until the work produces a verifiable artifact, then enter the interleave loop.
