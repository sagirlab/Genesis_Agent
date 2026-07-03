---
name: ritual-dapp-backend
description: Backend services for Ritual dApps. Use when building event indexers, APIs, job monitors, or webhook services for Ritual applications.
---

# Backend Services — Ritual dApp Patterns

## Overview

Ritual dApps with async precompiles need backend services to track job state, index on-chain events, and serve results to frontends. The async lifecycle means a user's transaction is committed in one block and settled blocks later — your backend bridges that gap.

**When you need a backend**:
- Your dApp uses async precompiles (anything that goes through `AsyncJobTracker`)
- You need to display job history or results after page refresh
- You want real-time updates via WebSocket/SSE instead of client-side polling
- You deliver results via webhooks to external services

### Architecture

```
┌──────────────┐         ┌──────────────────┐         ┌───────────────┐
│   Ritual     │  events │  Event Indexer    │  write  │   Database    │
│   Chain      │────────▶│  (watchEvent)     │────────▶│               │
│              │         │                   │         │  - jobs       │
│  ~350ms      │         │  - JobAdded       │         │  - events     │
│  blocks      │         │  - Phase1Settled  │         │  - results    │
│              │         │  - ResultDelivered│         │               │
└──────────────┘         └──────────────────┘         └───────┬───────┘
                                                              │
                          ┌──────────────────┐                │
                          │   Job Monitor    │────────────────│
                          │  (poll tracker)  │                │
                          └──────────────────┘                │
                                                              │
┌──────────────┐         ┌──────────────────┐                │
│   Frontend / │◀────────│   API Server     │◀───────────────┘
│   External   │  REST   │                  │
│   Client     │  WS/SSE │                  │
└──────────────┘         └──────────────────┘
```

All contract addresses, event signatures, struct definitions, and precompile classifications are in the `ritual-dapp-contracts` skill. This skill only covers backend-specific patterns that use those on-chain primitives.

---

## 1. Ritual Chain Specifics Your Backend Must Handle

Before writing any code, understand the constraints that make a Ritual backend different from a generic EVM backend.

### Conservative 350ms Block-Time Baseline

Use ~350ms as a conservative planning baseline for backend thresholds. Confirm live cadence on your target deployment with `ritual-dapp-block-time`.

| Concern | Implication |
|---------|------------|
| Event watcher throughput | Your `watchEvent` handler fires ~5x/second. Database writes must keep up. Use batch inserts or upserts. |
| Backfill chunk sizing | 2,000 blocks = ~6.7 minutes. For multi-hour downtime, backfill is fast. For multi-day downtime, you're processing 100k+ blocks per day. |
| Polling intervals | `pollIntervalMs: 5000` means checking every ~14,286 blocks at the 350ms baseline. Adjust based on expected job duration, not block count. |
| Indexer lag thresholds | 50 blocks behind = ~17.5 seconds. That's healthy. Don't alert until lag > 500 blocks (~175 seconds). |
| Reorg risk | Short reorgs are still possible at high throughput. Use upserts (not inserts) so replayed events don't create duplicates. |

### Sender Lock — One Async Job Per EOA

The Ritual chain enforces one unresolved async job per externally-owned account (via `AsyncJobTracker`). If your backend submits transactions on behalf of users, serialize submissions per EOA:

```typescript
const senderLocks = new Map<string, Promise<void>>();

async function submitWithSenderLock(sender: string, submitFn: () => Promise<void>) {
  const prev = senderLocks.get(sender) ?? Promise.resolve();
  const next = prev.then(submitFn).catch(() => {});
  senderLocks.set(sender, next);
  await next;
}
```

Before submitting, check sender lock status using `IAsyncJobTracker.hasPendingJobForSender` (see `ritual-dapp-contracts` for the full interface).

### Short-running async vs long-running async — Different Data Retrieval Paths

Your backend must route result extraction based on execution model. See the precompile table in `ritual-dapp-contracts` for which precompiles use which model.

- **Short-running async** (HTTP 0x0801, LLM 0x0802): Result is in the transaction receipt's `spcCalls` field. See section 2 below.
- **Long-running async** (Long HTTP, Image, Audio, Video, ZK, Persistent Agent, Sovereign Agent): Result arrives via callback to your consumer contract. Watch for your contract's result events.

### Canonical 9-State Job Lifecycle

Use these status names in your database — they provide a superset of the on-chain states with application-level granularity:

```typescript
type RitualJobStatus =
  | 'SUBMITTING'
  | 'PENDING_COMMITMENT'
  | 'COMMITTED'
  | 'EXECUTOR_PROCESSING'
  | 'RESULT_READY'
  | 'PENDING_SETTLEMENT'
  | 'SETTLED'
  | 'FAILED'
  | 'EXPIRED';
```

Map chain events to status transitions (event signatures are in `IAsyncJobTracker` in the `ritual-dapp-contracts` skill):

| Event | Status Transition |
|-------|------------------|
| Transaction submitted (your code) | → `SUBMITTING` |
| Transaction mined | → `PENDING_COMMITMENT` |
| `JobAdded` event | → `COMMITTED` (executor was assigned at job admission) |
| `Phase1Settled` event (long-running only — Phase 1 fees paid, Phase 2 deadline armed) | → `RESULT_READY` |
| `ResultDelivered` event (`success=true`) | → `SETTLED` |
| `ResultDelivered` event (`success=false`) | → `FAILED` |
| `JobRemoved(completed=true)` event | confirm `SETTLED` (short-running async — no `Phase1Settled` is emitted for these) |
| `JobRemoved(completed=false)` from cleanup | → `EXPIRED` |
| `AsyncDelivery.SettlementFailed` | → `FAILED` (RitualWallet insufficient for Phase 1) |
| `AsyncDelivery.DeliveryFailed` | → `FAILED` (RitualWallet insufficient for executor or callback gas+value) |
| Block exceeds `commitBlock + ttl` (long-running: `markPhase1Settled` extends to `commitBlock + maxPollBlock`) | → `EXPIRED` once the next cleanup pass removes the row |

> **`Phase1Settled` does not mean the job result is ready.** For long-running async (Long HTTP, Sovereign Agent, Persistent Agent, Image / Audio / Video, ZK, FHE) it means the executor's settlement TX paid Phase 1 fees and armed the Phase 2 deadline; the off-chain work runs *after* this event. For short-running async (HTTP, LLM, ONNX, JQ, DKMS) `Phase1Settled` is **never emitted** — the result lands in the receipt's `spcCalls` and `JobRemoved(completed=true)` fires.

---

## 2. spcCalls Receipt Extraction

The most Ritual-specific backend pattern. When a short-running async precompile (HTTP, LLM) settles, the actual result is in the transaction receipt's `spcCalls` field — not in an event.

```typescript
import { decodeAbiParameters, type Hex } from 'viem';

interface RitualReceipt {
  spcCalls?: Array<{ input: Hex; output: Hex }>;
}

async function extractSpcResult(txHash: Hex): Promise<{ input: Hex; output: Hex } | null> {
  const receipt = await publicClient.getTransactionReceipt({ hash: txHash });
  const spcCalls = (receipt as unknown as RitualReceipt).spcCalls;

  if (!spcCalls || spcCalls.length === 0) return null;
  return spcCalls[0];
}
```

### Precompile-Specific Result Decoding

Each precompile returns a different structure. Decode based on precompile address. The output ABI for each precompile is in `ritual-dapp-contracts` (see "Short-Running Async Output Envelope").

```typescript
async function decodeJobResult(job: { precompile: number; txHash: string }) {
  const spc = await extractSpcResult(job.txHash as Hex);
  if (!spc) return null;

  switch (job.precompile) {
    case 0x0801: {
      const [statusCode, headerKeys, headerValues, body, errorMessage] =
        decodeAbiParameters(
          [
            { type: 'uint16' },
            { type: 'string[]' },
            { type: 'string[]' },
            { type: 'bytes' },
            { type: 'string' },
          ],
          spc.output,
        );
      return {
        type: 'http',
        statusCode,
        headers: Object.fromEntries(headerKeys.map((k, i) => [k, headerValues[i]])),
        body: new TextDecoder().decode(body as Uint8Array),
        error: errorMessage || null,
      };
    }

    case 0x0802: {
      const [hasError, completionData, , errorMessage] =
        decodeAbiParameters(
          parseAbiParameters('bool, bytes, bytes, string, (string,string,string)'),
          spc.output,
        );

      if (hasError) return { type: 'llm', error: errorMessage };

      const [, , , model, , , , choicesData, usageData] = decodeAbiParameters(
        parseAbiParameters('string, string, uint256, string, string, string, uint256, bytes[], bytes'),
        completionData as Hex,
      );
      const [promptTokens, completionTokens, totalTokens] = decodeAbiParameters(
        parseAbiParameters('uint256, uint256, uint256'),
        usageData as Hex,
      );
      let content: string | null = null;
      if ((choicesData as any[]).length > 0) {
        const [, , messageData] = decodeAbiParameters(
          parseAbiParameters('uint256, string, bytes'),
          (choicesData as any[])[0] as Hex,
        );
        const [, msgContent] = decodeAbiParameters(
          parseAbiParameters('string, string, string, uint256, bytes[]'),
          messageData as Hex,
        );
        content = (msgContent as string) || null;
      }
      return {
        type: 'llm',
        content,
        model,
        usage: { promptTokens, completionTokens, totalTokens },
        error: null,
      };
    }

    default:
      return { type: 'unknown', raw: spc.output };
  }
}
```

### Integration: Extract and Cache on Settlement

When your event watcher detects settlement, immediately extract and store the decoded result:

```typescript
async function onJobSettled(jobId: string, txHash: string, precompile: number) {
  const isShortRunningAsync = [0x0801, 0x0802].includes(precompile);

  if (isShortRunningAsync) {
    const decoded = await decodeJobResult({ precompile, txHash });
    await db.updateJob(jobId, {
      status: 'SETTLED',
      result: decoded,
      settledAt: new Date(),
    });
  } else {
    await db.updateJob(jobId, {
      status: 'SETTLED',
      settledAt: new Date(),
    });
  }
}
```

For long-running async precompiles, the result arrives via the callback to your consumer contract. Watch for your consumer contract's result events (e.g., `AgentJobCompleted`, `LongRunningResultReceived`) to capture the result.

---

## 3. Event Indexer

Watches the chain for `AsyncJobTracker` events and persists them. Use the event signatures from `IAsyncJobTracker` in the `ritual-dapp-contracts` skill — do not hardcode event strings.

```typescript
import { createPublicClient, http, defineChain, type Address } from 'viem';

export const ritualChain = defineChain({
  id: 1979,
  name: 'Ritual',
  nativeCurrency: { name: 'RITUAL', symbol: 'RITUAL', decimals: 18 },
  rpcUrls: {
    default: { http: [process.env.RITUAL_RPC_URL ?? 'https://rpc.ritualfoundation.org'] },
  },
});

const ASYNC_JOB_TRACKER: Address = '0xC069FFCa0389f44eCA2C626e55491b0ab045AEF5';
```

Wire `publicClient.watchEvent` for each of the four tracker events (`JobAdded`, `Phase1Settled`, `ResultDelivered`, `JobRemoved`). On each event:

| Event | Action |
|-------|--------|
| `JobAdded` | Upsert job with `status: PENDING_COMMITMENT`, store `sender` (from `senderAddress` field), `precompile`, `commitBlock`, `ttl`, `txHash` |
| `Phase1Settled` | Update to `status: COMMITTED`, store `executor` |
| `ResultDelivered` | If `success=true`, call `onJobSettled`. If `success=false`, set `status: FAILED` |
| `JobRemoved` | Confirm `status: SETTLED` (if `completed=true`) |

Use `upsertJob` (not insert) so replayed events from reorgs or backfills don't create duplicates.

### Historical Backfill

On startup, backfill events from the last checkpoint before starting live watchers. This eliminates gaps in coverage.

```typescript
async function backfillEvents(db: Database, fromBlock: bigint) {
  const currentBlock = await publicClient.getBlockNumber();
  const CHUNK_SIZE = 5000n;

  for (let start = fromBlock; start <= currentBlock; start += CHUNK_SIZE) {
    const end = start + CHUNK_SIZE - 1n > currentBlock ? currentBlock : start + CHUNK_SIZE - 1n;

    const logs = await publicClient.getLogs({
      address: ASYNC_JOB_TRACKER,
      fromBlock: start,
      toBlock: end,
    });

    for (const log of logs) {
      // Decode based on topic[0] and upsert
    }

    await db.setCheckpoint('lastIndexedBlock', end.toString());
  }
}
```

---

## 4. Job Monitor

Polls `AsyncJobTracker.getJob` for jobs where events alone aren't sufficient (e.g., expiry detection). The `getJob` function returns a `Job` struct with 14 fields — see `IAsyncJobTracker` in `ritual-dapp-contracts` for the exact struct definition.

Key semantics for the monitor:

- **Expiry detection:** The `Job` struct has `commitBlock` and `ttl` but no `expiryBlock` field. Compute expiry as `commitBlock + ttl` and compare against the current block number.
- **Settlement detection for short-running async jobs:** When a short-running async job (HTTP, LLM) settles, it is **removed** from the tracker. A `getJob` call will revert with "not found". Catch this revert and treat it as settled (cross-check against your `ResultDelivered` event log).
- **Phase 1 detection for long-running async jobs:** The `phase1Settled` field is only meaningful for long-running async precompiles. It indicates Phase 1 is complete and the sender nonce lock is released, NOT that the final result has been delivered.

```typescript
async function monitorTick(db: Database) {
  const pendingJobs = await db.getJobsByStatus([
    'PENDING_COMMITMENT', 'COMMITTED', 'EXECUTOR_PROCESSING',
  ]);
  const currentBlock = await publicClient.getBlockNumber();

  for (const job of pendingJobs) {
    try {
      const [onChain] = await publicClient.readContract({
        address: ASYNC_JOB_TRACKER,
        abi: asyncJobTrackerAbi,
        functionName: 'getJob',
        args: [job.jobId as `0x${string}`],
      });

      const expiryBlock = BigInt(onChain.commitBlock) + BigInt(onChain.ttl);

      if (currentBlock > expiryBlock) {
        await db.updateJob(job.jobId, { status: 'EXPIRED' });
      } else if (
        onChain.executor !== '0x0000000000000000000000000000000000000000' &&
        job.status === 'PENDING_COMMITMENT'
      ) {
        await db.updateJob(job.jobId, {
          status: 'COMMITTED',
          executor: onChain.executor,
        });
      }
    } catch (err: any) {
      if (err.message?.includes('not found')) {
        await db.updateJob(job.jobId, { status: 'SETTLED' });
      } else {
        console.error(`Error polling job ${job.jobId}:`, err);
      }
    }
  }
}
```

---

## 5. Database Schema

The Ritual-specific data model. Adapt to your ORM of choice.

```sql
CREATE TABLE jobs (
  job_id          TEXT PRIMARY KEY,
  sender          TEXT NOT NULL,
  executor        TEXT,
  precompile      INTEGER NOT NULL,
  precompile_type TEXT GENERATED ALWAYS AS (
    CASE precompile
      WHEN 2049 THEN 'HTTP'
      WHEN 2050 THEN 'LLM'
      WHEN 2055 THEN 'FHE'
      WHEN 2053 THEN 'LONG_HTTP'
      WHEN 2054 THEN 'ZK'
      WHEN 2075 THEN 'DKMS'
      WHEN 2072 THEN 'IMAGE'
      WHEN 2073 THEN 'AUDIO'
      WHEN 2074 THEN 'VIDEO'
      WHEN 2060 THEN 'SOVEREIGN_AGENT'
      WHEN 2080 THEN 'PERSISTENT_AGENT'
      ELSE 'UNKNOWN'
    END
  ) STORED,
  execution_model TEXT GENERATED ALWAYS AS (
    CASE WHEN precompile IN (2049, 2050) THEN 'Short-Running' ELSE 'Long-Running' END
  ) STORED,
  status          TEXT NOT NULL DEFAULT 'SUBMITTING',
  result          JSONB,
  error           TEXT,
  tx_hash         TEXT,
  submitted_block INTEGER NOT NULL,
  ttl             INTEGER,
  callback_target TEXT,
  settled_at      TIMESTAMPTZ,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_jobs_sender ON jobs (sender);
CREATE INDEX idx_jobs_status ON jobs (status);
CREATE INDEX idx_jobs_created_at ON jobs (created_at DESC);
CREATE INDEX idx_jobs_precompile_type ON jobs (precompile_type);

CREATE TABLE events (
  id            SERIAL PRIMARY KEY,
  block_number  INTEGER NOT NULL,
  tx_hash       TEXT NOT NULL,
  log_index     INTEGER NOT NULL,
  event_name    TEXT NOT NULL,
  contract      TEXT NOT NULL,
  args          JSONB NOT NULL,
  indexed_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (tx_hash, log_index)
);

CREATE TABLE checkpoints (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
```

Key differences from a generic schema:
- `precompile_type` maps integer addresses to readable names (hex-to-decimal: 0x0801=2049, 0x0802=2050, etc.)
- `execution_model` distinguishes Short-Running (result in receipt) from Long-Running (result via callback)
- `status` uses the canonical 9-state lifecycle names
- `ttl` is persisted so expiry can be computed as `submitted_block + ttl` even if chain data is pruned
- `callback_target` tracks where long-running async results will be delivered

---

## 6. Real-Time Job Updates

### WebSocket Subscription Model

Clients subscribe by jobId or by user address. The backend broadcasts on every lifecycle state transition.

```typescript
type Subscription = { type: 'job'; jobId: string } | { type: 'user'; address: string };

const subscribers = new Map<WebSocket, Set<string>>();

function broadcastJobUpdate(jobId: string, sender: string, update: Record<string, unknown>) {
  const message = JSON.stringify({ type: 'job_update', jobId, ...update });
  const jobKey = `job:${jobId}`;
  const userKey = `user:${sender.toLowerCase()}`;

  for (const [ws, subs] of subscribers) {
    if (ws.readyState === 1 && (subs.has(jobKey) || subs.has(userKey) || subs.has('all'))) {
      ws.send(message);
    }
  }
}
```

### SSE for Single-Job Tracking

Auto-closes when the job reaches a terminal state:

```typescript
app.get('/api/jobs/:jobId/stream', async (request, reply) => {
  const { jobId } = request.params as { jobId: string };

  reply.raw.writeHead(200, {
    'Content-Type': 'text/event-stream',
    'Cache-Control': 'no-cache',
    Connection: 'keep-alive',
  });

  const sendEvent = (data: unknown) => {
    reply.raw.write(`data: ${JSON.stringify(data)}\n\n`);
  };

  const current = await db.getJob(jobId);
  if (current) sendEvent({ status: current.status, result: current.result });

  const TERMINAL = ['SETTLED', 'FAILED', 'EXPIRED'];

  const listener = (update: { jobId: string; status: string }) => {
    if (update.jobId === jobId) {
      sendEvent(update);
      if (TERMINAL.includes(update.status)) reply.raw.end();
    }
  };

  jobEmitter.on('update', listener);
  request.raw.on('close', () => jobEmitter.off('update', listener));
});
```

---

## 7. Application Bootstrap

The Ritual-specific boot sequence matters — order determines correctness:

1. **Backfill** events from last checkpoint BEFORE starting live watchers (no gap in event coverage)
2. **Start live event watchers** (after backfill completes)
3. **Start job monitor** (after watchers — it reads from the same DB)
4. **Start API server** (after all data sources are live)
5. **Graceful shutdown** in reverse order

**Ritual-specific env vars** (everything else is standard Node.js config):

```bash
RITUAL_RPC_URL=https://rpc.ritualfoundation.org
RITUAL_WS_URL=wss://rpc.ritualfoundation.org/ws
```

---

## Quick Reference

| Item | Value |
|------|-------|
| AsyncJobTracker | `0xC069FFCa0389f44eCA2C626e55491b0ab045AEF5` |
| TEEServiceRegistry | `0x9644e8562cE0Fe12b4deeC4163c064A8862Bf47F` |
| RitualWallet | `0x532F0dF0896F353d8C3DD8cc134e8129DA2a3948` |
| AsyncDelivery | `0x5A16214fF555848411544b005f7Ac063742f39F6` |
| Chain ID | 1979 |
| Block time | ~350ms (conservative baseline) |
| RPC (HTTP) | `https://rpc.ritualfoundation.org` |
| RPC (WebSocket) | `wss://rpc.ritualfoundation.org/ws` |
| Sender lock | One pending async job per EOA |
| Lifecycle states | SUBMITTING → PENDING_COMMITMENT → COMMITTED → EXECUTOR_PROCESSING → RESULT_READY → PENDING_SETTLEMENT → SETTLED / FAILED / EXPIRED |

### Related Skills

| Skill | What it covers |
|-------|---------------|
| `ritual-dapp-contracts` | All contract ABIs, event signatures (`IAsyncJobTracker`), precompile table, capability enum |
| `ritual-dapp-frontend` | Client-side hooks, wallet integration, event watching from the browser |
| `ritual-dapp-http` | HTTP precompile request/response ABI (canonical 13-field format), encoding patterns |
| `ritual-dapp-llm` | LLM precompile ABI, model selection, conversation history |
| `ritual-dapp-testing` | Foundry unit/fork/fuzz tests, mock precompile patterns, debugging guide |
| `ritual-dapp-longrunning` | Long-running async callback patterns, delivery configuration, agent/long-HTTP specifics |
| `ritual-dapp-wallet` | Deposit flows, lock duration, balance management |
