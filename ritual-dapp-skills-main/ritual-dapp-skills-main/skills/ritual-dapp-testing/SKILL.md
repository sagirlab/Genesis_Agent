---
name: ritual-dapp-testing
description: Testing and debugging patterns for Ritual dApps. Use when writing tests, debugging issues, or setting up CI/CD for Ritual applications.
---

# Testing & Debugging — Ritual dApp Patterns

## Overview

Ritual dApps span multiple layers — Solidity contracts, TypeScript viem interactions, backend services, and frontends — each requiring a different testing strategy. The async nature of Ritual precompiles adds complexity: a single user action may touch commit, execute, and settle phases across multiple blocks.

### Testing Pyramid for Ritual dApps

```
                    ┌─────────────────┐
                    │   E2E Tests     │  Few, slow, high confidence
                    │  (Real chain)   │  Real executors
                    ├─────────────────┤
                    │  Integration    │  Moderate count
                    │  Tests          │  viem ↔ chain, fork tests
                    ├─────────────────┤
                    │  Unit Tests     │  Many, fast, isolated
                    │  (Foundry +     │  Contracts + codecs + hooks
                    │   Vitest)       │
                    └─────────────────┘
```

| Layer | Tool | What It Tests | Speed |
|-------|------|---------------|-------|
| Solidity unit tests | Foundry (`forge test`) | Contract logic, encoding, access control | Fast (~1s) |
| Solidity fuzz tests | Foundry (`forge test`) | Edge cases via randomized inputs | Medium (~10s) |
| Solidity fork tests | Foundry (`forge test --fork-url`) | Against live chain state | Slow (~30s) |
| viem codec tests | Vitest / Jest | Encode/decode round-trips, type safety | Fast (~1s) |
| viem integration tests | Vitest / Jest | Real transactions on chain | Slow (~60s) |
| Backend unit tests | Vitest | Event parsing, DB queries, webhook signing | Fast (~1s) |
| Frontend component tests | React Testing Library | Hook state machines, UI rendering | Fast (~2s) |
| E2E acceptance tests | Playwright + chain | Full user flow through real chain | Very slow (~120s) |

---

## 1. Foundry Unit Tests

### Basic Consumer Contract Test

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

contract HTTPConsumer {
    address constant HTTP_PRECOMPILE = address(0x0801);
    event ResponseReceived(uint16 status, string body);

    function decodeSettlement(bytes memory rawOutput)
        public
        pure
        returns (uint16 status, bytes memory body, string memory err)
    {
        (, bytes memory actualOutput) = abi.decode(rawOutput, (bytes, bytes));
        (status, , , body, err) = abi.decode(
            actualOutput,
            (uint16, string[], string[], bytes, string)
        );
    }

    function fetchData(address executor, uint256 ttl, string calldata url)
        external
        returns (uint16 status, bytes memory body)
    {
        bytes memory input = abi.encode(
            executor, new bytes[](0), ttl, new bytes[](0), bytes(""),
            url, uint8(1), new string[](0), new string[](0), bytes(""),
            uint256(0), uint8(0), false
        );
        (bool success, bytes memory rawOutput) = HTTP_PRECOMPILE.call(input);
        require(success, "Precompile call failed");
        string memory err;
        (status, body, err) = decodeSettlement(rawOutput);
        require(bytes(err).length == 0, err);
        emit ResponseReceived(status, string(body));
        return (status, body);
    }
}

contract HTTPConsumerTest is Test {
    HTTPConsumer consumer;
    address executor = makeAddr("executor");

    function setUp() public {
        consumer = new HTTPConsumer();
        vm.deal(address(consumer), 10 ether);
    }

    function test_DecodeSettlement_UnwrapsSpcEnvelope() public {
        bytes memory rawOutput = abi.encode(
            bytes("simulated-input"),
            abi.encode(
                uint16(200),
                new string[](0),
                new string[](0),
                bytes('{"price": 3500}'),
                ""
            )
        );

        (uint16 status, bytes memory body, string memory err) =
            consumer.decodeSettlement(rawOutput);

        assertEq(status, 200);
        assertEq(string(body), '{"price": 3500}');
        assertEq(err, "");
    }

    function test_FetchData_EmitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit HTTPConsumer.ResponseReceived(200, '{"price": 3500}');

        bytes memory rawOutput = abi.encode(
            bytes("simulated-input"),
            abi.encode(
                uint16(200),
                new string[](0),
                new string[](0),
                bytes('{"price": 3500}'),
                ""
            )
        );
        (uint16 status, bytes memory body, string memory err) =
            consumer.decodeSettlement(rawOutput);
        require(bytes(err).length == 0, err);
        emit HTTPConsumer.ResponseReceived(status, string(body));
    }
}
```

### Async Consumer with Callback Tests

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

contract AsyncConsumer {
    address constant LONG_HTTP_PRECOMPILE = address(0x0805);
    address public deliveryAddress;

    mapping(bytes32 => bool) public pendingJobs;
    mapping(bytes32 => bytes) public results;

    event JobSubmitted(bytes32 indexed jobId);
    event JobCompleted(bytes32 indexed jobId, bytes result);

    constructor(address _deliveryAddress) {
        deliveryAddress = _deliveryAddress;
    }

    function submitJob(bytes calldata input) external {
        (bool success, bytes memory result) = LONG_HTTP_PRECOMPILE.call(input);
        require(success, "Precompile call failed");
        bytes32 jobId = keccak256(result);
        pendingJobs[jobId] = true;
        emit JobSubmitted(jobId);
    }

    function onResult(bytes32 jobId, bytes calldata result) external {
        require(msg.sender == deliveryAddress, "Unauthorized delivery");
        require(pendingJobs[jobId], "Unknown job");

        pendingJobs[jobId] = false;
        results[jobId] = result;
        emit JobCompleted(jobId, result);
    }
}

contract AsyncConsumerTest is Test {
    AsyncConsumer consumer;
    address delivery = makeAddr("delivery");
    address attacker = makeAddr("attacker");
    bytes32 jobId = keccak256("test-job");

    function setUp() public {
        consumer = new AsyncConsumer(delivery);
    }

    function test_OnResult_StoresResult() public {
        // Simulate pending job
        vm.store(
            address(consumer),
            keccak256(abi.encode(jobId, uint256(1))), // pendingJobs slot
            bytes32(uint256(1))
        );

        bytes memory result = abi.encode("hello world");

        vm.prank(delivery);
        consumer.onResult(jobId, result);

        assertEq(consumer.results(jobId), result);
    }

    function test_OnResult_RevertsUnauthorized() public {
        vm.store(
            address(consumer),
            keccak256(abi.encode(jobId, uint256(1))),
            bytes32(uint256(1))
        );

        vm.prank(attacker);
        vm.expectRevert("Unauthorized delivery");
        consumer.onResult(jobId, "");
    }

    function test_OnResult_RevertsUnknownJob() public {
        vm.prank(delivery);
        vm.expectRevert("Unknown job");
        consumer.onResult(jobId, "");
    }

    function test_OnResult_EmitsEvent() public {
        vm.store(
            address(consumer),
            keccak256(abi.encode(jobId, uint256(1))),
            bytes32(uint256(1))
        );

        bytes memory result = abi.encode("data");

        vm.expectEmit(true, false, false, true);
        emit AsyncConsumer.JobCompleted(jobId, result);

        vm.prank(delivery);
        consumer.onResult(jobId, result);
    }
}
```

### Fuzz Testing Fee Calculations

```solidity
contract FeeCalculatorTest is Test {
    uint256 constant BASE_FEE = 2_500_000_000_000; // 0.0000025 RITUAL
    uint256 constant PER_BYTE_FEE = 350_000_000; // 0.35 gwei/byte input
    uint256 constant MAX_INPUT_SIZE = 10 * 1024; // 10KB async input cap

    function calculateFee(uint256 inputSize) internal pure returns (uint256) {
        require(inputSize <= MAX_INPUT_SIZE, "Input too large");
        return BASE_FEE + (inputSize * PER_BYTE_FEE);
    }

    function testFuzz_FeeCalculation(uint256 inputSize) public pure {
        inputSize = bound(inputSize, 0, MAX_INPUT_SIZE);
        uint256 fee = calculateFee(inputSize);
        assertGe(fee, BASE_FEE);
        assertLe(fee, BASE_FEE + MAX_INPUT_SIZE * PER_BYTE_FEE);
    }

    function testFuzz_FeeMonotonicallyIncreases(uint256 a, uint256 b) public pure {
        a = bound(a, 0, MAX_INPUT_SIZE - 1);
        b = bound(b, a + 1, MAX_INPUT_SIZE);
        assertLt(calculateFee(a), calculateFee(b));
    }

    function testFuzz_FeeRevertsOverMax(uint256 inputSize) public {
        inputSize = bound(inputSize, MAX_INPUT_SIZE + 1, type(uint256).max);
        vm.expectRevert("Input too large");
        this.calculateFeeExternal(inputSize);
    }

    function calculateFeeExternal(uint256 inputSize) external pure returns (uint256) {
        return calculateFee(inputSize);
    }
}
```

---

## 2. Mock Precompile Responses

In unit tests, precompile addresses aren't available. Use `vm.mockCall` or etch bytecode to simulate responses.

### Using vm.mockCall

```solidity
contract MockPrecompileTest is Test {
    address constant HTTP_PRECOMPILE = address(0x0801);

    function test_MockHTTPResponse() public {
        // Async precompile results are wrapped in a short-running async envelope: (bytes simulatedInput, bytes actualOutput)
        bytes memory innerResponse = abi.encode(
            uint16(200),
            new string[](0),
            new string[](0),
            bytes('{"result": "ok"}'),
            ""
        );
        bytes memory spcEnvelope = abi.encode(bytes("simulated-input"), innerResponse);

        vm.mockCall(
            HTTP_PRECOMPILE,
            "",
            spcEnvelope
        );

        (bool success, bytes memory result) = HTTP_PRECOMPILE.call(
            abi.encode("anything")
        );
        assertTrue(success);

        // Unwrap short-running async envelope, then decode inner response
        (, bytes memory actualOutput) = abi.decode(result, (bytes, bytes));
        (uint16 status, , , bytes memory body, ) =
            abi.decode(actualOutput, (uint16, string[], string[], bytes, string));
        assertEq(status, 200);
        assertEq(string(body), '{"result": "ok"}');
    }
}
```

### Using vm.etch for Complex Mocks

```solidity
contract PrecompileMock {
    fallback(bytes calldata input) external returns (bytes memory) {
        bytes memory innerResponse = abi.encode(
            uint16(200),
            new string[](0),
            new string[](0),
            bytes('{"mocked": true}'),
            ""
        );
        return abi.encode(input, innerResponse); // short-running async envelope: (simulatedInput, actualOutput)
    }
}

contract EtchMockTest is Test {
    address constant HTTP_PRECOMPILE = address(0x0801);

    function setUp() public {
        PrecompileMock mock = new PrecompileMock();
        vm.etch(HTTP_PRECOMPILE, address(mock).code);
    }

    function test_PrecompileReturnsFixedResponse() public {
        (bool ok, bytes memory result) = HTTP_PRECOMPILE.call(abi.encode("test"));
        assertTrue(ok);

        (, bytes memory actualOutput) = abi.decode(result, (bytes, bytes));
        (, , , bytes memory body, ) =
            abi.decode(actualOutput, (uint16, string[], string[], bytes, string));
        assertEq(string(body), '{"mocked": true}');
    }
}
```

### Parameterized Mock — Return Different Results per Input

```solidity
contract ParameterizedMock {
    mapping(bytes32 => bytes) public responses;

    function setResponse(bytes32 inputHash, bytes calldata response) external {
        responses[inputHash] = response;
    }

    fallback(bytes calldata input) external returns (bytes memory) {
        bytes32 key = keccak256(input);
        bytes memory resp = responses[key];
        require(resp.length > 0, "No mock response for input");
        return resp;
    }
}

contract ParameterizedMockTest is Test {
    address constant HTTP_PRECOMPILE = address(0x0801);
    ParameterizedMock mock;

    function setUp() public {
        mock = new ParameterizedMock();
        vm.etch(HTTP_PRECOMPILE, address(mock).code);
    }

    function test_DifferentResponsesPerInput() public {
        bytes memory input1 = abi.encode("https://api.example.com/a");
        bytes memory input2 = abi.encode("https://api.example.com/b");

        bytes memory inner1 = abi.encode(uint16(200), new string[](0), new string[](0), bytes("A"), "");
        bytes memory inner2 = abi.encode(uint16(200), new string[](0), new string[](0), bytes("B"), "");

        mock.setResponse(keccak256(input1), abi.encode(input1, inner1));
        mock.setResponse(keccak256(input2), abi.encode(input2, inner2));

        (, bytes memory r1) = HTTP_PRECOMPILE.call(input1);
        (, bytes memory r2) = HTTP_PRECOMPILE.call(input2);

        (, bytes memory out1) = abi.decode(r1, (bytes, bytes));
        (, bytes memory out2) = abi.decode(r2, (bytes, bytes));
        (, , , bytes memory body1, ) = abi.decode(out1, (uint16, string[], string[], bytes, string));
        (, , , bytes memory body2, ) = abi.decode(out2, (uint16, string[], string[], bytes, string));

        assertEq(string(body1), "A");
        assertEq(string(body2), "B");
    }
}
```

---

## 3. Fork Testing — Test Against Live Ritual Chain

Fork testing runs your contracts against real chain state, including real system contracts and precompile behavior.

### Basic Fork Test

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

contract ForkTest is Test {
    address constant RITUAL_WALLET = 0x532F0dF0896F353d8C3DD8cc134e8129DA2a3948;
    address constant ASYNC_JOB_TRACKER = 0xC069FFCa0389f44eCA2C626e55491b0ab045AEF5;
    address constant TEE_SERVICE_REGISTRY = 0x9644e8562cE0Fe12b4deeC4163c064A8862Bf47F;

    uint256 ritualFork;

    function setUp() public {
        ritualFork = vm.createFork(vm.envString("RITUAL_RPC_URL"));
        vm.selectFork(ritualFork);
    }

    function test_RitualWalletDeposit() public {
        address user = makeAddr("user");
        vm.deal(user, 1 ether);

        vm.prank(user);
        (bool ok,) = RITUAL_WALLET.call{value: 0.1 ether}(
            abi.encodeWithSignature("deposit(uint256)", 100) // 100 = lock duration in blocks
        );
        assertTrue(ok, "Deposit failed");

        (bool ok2, bytes memory result) = RITUAL_WALLET.call(
            abi.encodeWithSignature("balanceOf(address)", user)
        );
        assertTrue(ok2);
        uint256 balance = abi.decode(result, (uint256));
        assertGe(balance, 0.1 ether);
    }

    function test_TEERegistryHasExecutors() public {
        (bool ok, bytes memory result) = TEE_SERVICE_REGISTRY.call(
            abi.encodeWithSignature("getServicesByCapability(uint8,bool)", uint8(0), false) // HTTP_CALL
        );
        assertTrue(ok, "Registry query failed");
    }

    function test_AsyncJobTrackerJobCount() public {
        address executor = address(0x1234);
        (bool ok, bytes memory result) = ASYNC_JOB_TRACKER.call(
            abi.encodeWithSignature("getJobCount(address)", executor)
        );
        assertTrue(ok);
        uint256 count = abi.decode(result, (uint256));
        console.log("Active jobs for executor:", count);
    }
}
```

### Fork Test with Contract Deployment

```solidity
contract DeployAndTestOnFork is Test {
    HTTPConsumer consumer;

    function setUp() public {
        vm.createSelectFork(vm.envString("RITUAL_RPC_URL"));

        consumer = new HTTPConsumer();
        vm.deal(address(consumer), 1 ether);

        // Deposit fees in RitualWallet
        vm.prank(address(consumer));
        (bool ok,) = address(0x532F0dF0896F353d8C3DD8cc134e8129DA2a3948).call{value: 0.1 ether}(
            abi.encodeWithSignature("deposit(uint256)", 200) // 200 = lock duration in blocks
        );
        assertTrue(ok);
    }

    function test_SubmitHTTPRequest_OnFork() public {
        // This will create a real commitment on the forked state
        consumer.fetchData(
            address(0x1234), // executor address from registry
            100,
            "https://api.example.com/test"
        );
    }
}
```

### Foundry Configuration for Fork Tests

```toml
# foundry.toml
[profile.default]
src = "src"
out = "out"
libs = ["lib"]
solc_version = "0.8.24"

[profile.fork]
fork_url = "${RITUAL_RPC_URL}"
fork_block_number = 0  # latest

[rpc_endpoints]
ritual = "${RITUAL_RPC_URL}"
```

Run fork tests: `RITUAL_RPC_URL=https://rpc.ritualfoundation.org forge test --match-contract ForkTest -vvv`

### eth_call Behavior with Precompiles

When testing precompiles via `eth_call` (read-only simulation), behavior differs between sync and async precompiles.

**Sync precompiles** (ONNX, JQ, Ed25519): execute normally and return real computation results. Standard `eth_call` testing works.

**All async precompiles** (HTTP 0x0801, LLM 0x0802, Long HTTP 0x0805, Sovereign Agent 0x080C, etc.): the EVM injects a default `AsyncCommitmentContext` in `Building` mode with empty `pending_spc_calls`. Each precompile hits the "fresh simulation" code path and returns:

```
abi.encode(bytes callInput, bytes empty)
```

The call succeeds (no revert), but the output's second element is always empty bytes — no actual HTTP response, LLM result, or task ID is returned. This is the short-running async envelope `(bytes simulatedInput, bytes actualOutput)` with `actualOutput = ""`.

To test async precompiles, submit a real transaction and wait for settlement, or use `vm.mockCall` / `vm.etch` (Section 2) for unit tests.

---

## 4. Precompile Encoding Unit Tests (Vitest)

### ABI Encoding Round-Trip Tests

```typescript
import { describe, it, expect } from 'vitest';
import { encodeAbiParameters, decodeAbiParameters, type Address } from 'viem';

const HTTP_REQUEST_TYPES = [
  { name: 'executor', type: 'address' },
  { name: 'encryptedSecrets', type: 'bytes[]' },
  { name: 'ttl', type: 'uint256' },
  { name: 'secretSignatures', type: 'bytes[]' },
  { name: 'userPublicKey', type: 'bytes' },
  { name: 'url', type: 'string' },
  { name: 'method', type: 'uint8' },
  { name: 'headerKeys', type: 'string[]' },
  { name: 'headerValues', type: 'string[]' },
  { name: 'body', type: 'bytes' },
  { name: 'dkmsKeyIndex', type: 'uint256' },
  { name: 'dkmsKeyFormat', type: 'uint8' },
  { name: 'piiEnabled', type: 'bool' },
] as const;

const HTTP_RESPONSE_TYPES = [
  { type: 'uint16' },
  { type: 'string[]' },
  { type: 'string[]' },
  { type: 'bytes' },
  { type: 'string' },
] as const;

describe('HTTP Call request encoding', () => {
  const executor: Address = '0x1234567890abcdef1234567890abcdef12345678';

  it('encodes and decodes a GET request', () => {
    const encoded = encodeAbiParameters(HTTP_REQUEST_TYPES, [
      executor, [], 100n, [], '0x',
      'https://api.example.com/data', 1, ['Accept'], ['application/json'],
      new TextEncoder().encode(''),
      0n, 0, false,
    ]);
    expect(encoded).toMatch(/^0x/);

    const decoded = decodeAbiParameters(HTTP_REQUEST_TYPES, encoded);
    expect(decoded[0]).toBe(executor);
    expect(decoded[5]).toBe('https://api.example.com/data');
    expect(decoded[6]).toBe(1); // GET
    expect(decoded[7]).toEqual(['Accept']);
    expect(decoded[8]).toEqual(['application/json']);
    expect(decoded[2]).toBe(100n);
  });

  it('encodes and decodes a POST request with body', () => {
    const body = JSON.stringify({ query: 'test' });

    const encoded = encodeAbiParameters(HTTP_REQUEST_TYPES, [
      executor, [], 200n, [], '0x',
      'https://api.example.com/query', 2,
      ['Content-Type'], ['application/json'],
      new TextEncoder().encode(body),
      0n, 0, false,
    ]);

    const decoded = decodeAbiParameters(HTTP_REQUEST_TYPES, encoded);
    expect(decoded[5]).toBe('https://api.example.com/query');
    expect(decoded[6]).toBe(2); // POST
    expect(new TextDecoder().decode(decoded[9] as Uint8Array)).toBe(body);
  });

  it('handles empty headers and body', () => {
    const encoded = encodeAbiParameters(HTTP_REQUEST_TYPES, [
      executor, [], 50n, [], '0x',
      'https://test.com', 1, [], [],
      new Uint8Array(),
      0n, 0, false,
    ]);

    const decoded = decodeAbiParameters(HTTP_REQUEST_TYPES, encoded);
    expect(decoded[7]).toEqual([]); // headerKeys
    expect(decoded[8]).toEqual([]); // headerValues
  });
});

describe('HTTP Call response decoding', () => {
  it('decodes a success response', () => {
    const encoded = encodeAbiParameters(HTTP_RESPONSE_TYPES, [
      200,
      ['content-type'],
      ['application/json'],
      new TextEncoder().encode('{"price": 3500}'),
      '',
    ]);

    const [statusCode, , , body, errorMessage] =
      decodeAbiParameters(HTTP_RESPONSE_TYPES, encoded);

    expect(statusCode).toBe(200);
    expect(errorMessage).toBe('');
    expect(JSON.parse(new TextDecoder().decode(body as Uint8Array))).toEqual({ price: 3500 });
  });

  it('decodes an error response', () => {
    const encoded = encodeAbiParameters(HTTP_RESPONSE_TYPES, [
      0, [], [], new Uint8Array(), 'executor timeout',
    ]);

    const [statusCode, , , , errorMessage] =
      decodeAbiParameters(HTTP_RESPONSE_TYPES, encoded);

    expect(statusCode).toBe(0);
    expect(errorMessage).toBe('executor timeout');
  });

  it('round-trips through ABI encoding', () => {
    const bodyText = 'hello';
    const encoded = encodeAbiParameters(HTTP_RESPONSE_TYPES, [
      200, [], [], new TextEncoder().encode(bodyText), '',
    ]);

    const [statusCode, , , body] = decodeAbiParameters(HTTP_RESPONSE_TYPES, encoded);
    expect(statusCode).toBe(200);
    expect(new TextDecoder().decode(body as Uint8Array)).toBe('hello');
  });
});
```

### Executor Query Tests

For executor discovery tests (`getServicesByCapability`, TEEServiceRegistry ABI, mock executor responses), see `ritual-dapp-deploy` and `ritual-dapp-contracts`.

---

## 5. Integration Tests — viem Against Ritual Chain

Integration tests send real transactions to Ritual Chain. They require RITUAL balance and take longer to run.

### Setup

```typescript
// test/setup.ts
import { createPublicClient, createWalletClient, http, defineChain } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';

export const ritualChain = defineChain({
  id: 1979,
  name: 'Ritual',
  nativeCurrency: { name: 'RITUAL', symbol: 'RITUAL', decimals: 18 },
  rpcUrls: {
    default: { http: [process.env.RITUAL_RPC_URL ?? 'https://rpc.ritualfoundation.org'] },
  },
  blockExplorers: {
    default: { name: 'Ritual Explorer', url: 'https://explorer.ritualfoundation.org' },
  },
});

export function getTestClients() {
  if (!process.env.RITUAL_RPC_URL || !process.env.TEST_PRIVATE_KEY) {
    throw new Error('RITUAL_RPC_URL and TEST_PRIVATE_KEY required for integration tests');
  }

  const account = privateKeyToAccount(process.env.TEST_PRIVATE_KEY as `0x${string}`);

  const publicClient = createPublicClient({
    chain: ritualChain,
    transport: http(process.env.RITUAL_RPC_URL),
  });

  const walletClient = createWalletClient({
    account,
    chain: ritualChain,
    transport: http(process.env.RITUAL_RPC_URL),
  });

  return { publicClient, walletClient, account };
}
```

### HTTP Call Integration Test

```typescript
import { describe, it, expect, beforeAll } from 'vitest';
import { getTestClients } from './setup';
import { parseEther, encodeAbiParameters, type Address } from 'viem';

const RITUAL_WALLET: Address = '0x532F0dF0896F353d8C3DD8cc134e8129DA2a3948';
const HTTP_PRECOMPILE: Address = '0x0000000000000000000000000000000000000801';

const ritualWalletAbi = [
  { name: 'balanceOf', type: 'function', stateMutability: 'view',
    inputs: [{ name: 'user', type: 'address' }], outputs: [{ type: 'uint256' }] },
  { name: 'deposit', type: 'function', stateMutability: 'payable',
    inputs: [{ name: 'lockDuration', type: 'uint256' }], outputs: [] },
] as const;

describe('HTTP Call (integration)', () => {
  let clients: ReturnType<typeof getTestClients>;

  beforeAll(async () => {
    clients = getTestClients();

    const balance = await clients.publicClient.readContract({
      address: RITUAL_WALLET,
      abi: ritualWalletAbi,
      functionName: 'balanceOf',
      args: [clients.account.address],
    });

    if (balance < parseEther('0.01')) {
      const hash = await clients.walletClient.writeContract({
        address: RITUAL_WALLET,
        abi: ritualWalletAbi,
        functionName: 'deposit',
        args: [5000n],
        value: parseEther('0.05'),
      });
      await clients.publicClient.waitForTransactionReceipt({ hash });
    }
  }, 30_000);

  it('submits a GET request and receives a transaction hash', async () => {
    const executor: Address = '0x...'; // selected executor from TEEServiceRegistry

    const encoded = encodeAbiParameters(
      [
        { name: 'executor', type: 'address' },
        { name: 'encryptedSecrets', type: 'bytes[]' },
        { name: 'ttl', type: 'uint256' },
        { name: 'secretSignatures', type: 'bytes[]' },
        { name: 'userPublicKey', type: 'bytes' },
        { name: 'url', type: 'string' },
        { name: 'method', type: 'uint8' },
        { name: 'headerKeys', type: 'string[]' },
        { name: 'headerValues', type: 'string[]' },
        { name: 'body', type: 'bytes' },
        { name: 'dkmsKeyIndex', type: 'uint256' },
        { name: 'dkmsKeyFormat', type: 'uint8' },
        { name: 'piiEnabled', type: 'bool' },
      ],
      [
        executor, [], 100n, [], '0x',
        'https://httpbin.org/get', 1, [], [],
        new Uint8Array(),
        0n, 0, false,
      ]
    );

    const hash = await clients.walletClient.sendTransaction({
      to: HTTP_PRECOMPILE,
      data: encoded,
      gas: 2_000_000n,
    });

    expect(hash).toMatch(/^0x[0-9a-f]{64}$/);

    const receipt = await clients.publicClient.waitForTransactionReceipt({ hash });
    expect(receipt.status).toBe('success');
  }, 60_000);
});
```

### Wallet Integration Test

```typescript
import { describe, it, expect, beforeAll } from 'vitest';
import { getTestClients } from './setup';
import { parseEther, type Address } from 'viem';

const RITUAL_WALLET: Address = '0x532F0dF0896F353d8C3DD8cc134e8129DA2a3948';

const ritualWalletAbi = [
  { name: 'balanceOf', type: 'function', stateMutability: 'view',
    inputs: [{ name: 'user', type: 'address' }], outputs: [{ type: 'uint256' }] },
  { name: 'deposit', type: 'function', stateMutability: 'payable',
    inputs: [{ name: 'lockDuration', type: 'uint256' }], outputs: [] },
] as const;

describe('RitualWallet (integration)', () => {
  let clients: ReturnType<typeof getTestClients>;

  beforeAll(() => {
    clients = getTestClients();
  });

  it('deposits and reads balance', async () => {
    const before = await clients.publicClient.readContract({
      address: RITUAL_WALLET,
      abi: ritualWalletAbi,
      functionName: 'balanceOf',
      args: [clients.account.address],
    });

    const hash = await clients.walletClient.writeContract({
      address: RITUAL_WALLET,
      abi: ritualWalletAbi,
      functionName: 'deposit',
      args: [5000n],
      value: parseEther('0.001'),
    });
    await clients.publicClient.waitForTransactionReceipt({ hash });

    const after = await clients.publicClient.readContract({
      address: RITUAL_WALLET,
      abi: ritualWalletAbi,
      functionName: 'balanceOf',
      args: [clients.account.address],
    });

    expect(after).toBeGreaterThan(before);
  }, 30_000);
});
```

---

## 6. Frontend Testing

For frontend component and hook testing patterns (React Testing Library, wagmi mocks, state machine transitions), see `ritual-dapp-frontend`.

---

## 7. Debugging Guide

### Common Issues and Solutions

#### Transaction stuck in pending

**Symptoms**: Transaction submitted successfully but job never settles.

**Diagnosis**:
```typescript
import { createPublicClient, http, defineChain, type Address, type Hex } from 'viem';

const ritualChain = defineChain({
  id: 1979,
  name: 'Ritual',
  nativeCurrency: { name: 'RITUAL', symbol: 'RITUAL', decimals: 18 },
  rpcUrls: {
    default: { http: [process.env.RITUAL_RPC_URL ?? 'https://rpc.ritualfoundation.org'] },
  },
});

const publicClient = createPublicClient({
  chain: ritualChain,
  transport: http(process.env.RITUAL_RPC_URL),
});

const TEE_SERVICE_REGISTRY: Address = '0x9644e8562cE0Fe12b4deeC4163c064A8862Bf47F';
const ASYNC_JOB_TRACKER: Address = '0xC069FFCa0389f44eCA2C626e55491b0ab045AEF5';

// 1. Check if services are available for your precompile type
const services = await publicClient.readContract({
  address: TEE_SERVICE_REGISTRY,
  abi: [{
    name: 'getServicesByCapability',
    type: 'function',
    stateMutability: 'view',
    inputs: [{ name: 'capability', type: 'uint8' }, { name: 'checkValidity', type: 'bool' }],
    outputs: [{ type: 'tuple[]', components: [
      { name: 'node', type: 'tuple', components: [
        { name: 'paymentAddress', type: 'address' },
        { name: 'teeAddress', type: 'address' },
        { name: 'teeType', type: 'uint8' },
        { name: 'publicKey', type: 'bytes' },
        { name: 'endpoint', type: 'string' },
        { name: 'certPubKeyHash', type: 'bytes32' },
        { name: 'capability', type: 'uint8' },
      ]},
      { name: 'isValid', type: 'bool' },
      { name: 'workloadId', type: 'bytes32' },
    ] }],
  }] as const,
  functionName: 'getServicesByCapability',
  args: [0, true], // 0 = HTTP_CALL capability
});
console.log('Available services:', services.length);

if (services.length === 0) {
  console.error('No services registered for HTTP_CALL capability');
  console.log('Check TEEServiceRegistry at', TEE_SERVICE_REGISTRY);
}

// 2. Check sender lock on AsyncJobTracker
const isLocked = await publicClient.readContract({
  address: ASYNC_JOB_TRACKER,
  abi: [{
    name: 'hasPendingJobForSender', type: 'function', stateMutability: 'view',
    inputs: [{ name: 'sender', type: 'address' }],
    outputs: [{ type: 'bool' }],
  }] as const,
  functionName: 'hasPendingJobForSender',
  args: [testEOA],
});
console.log('Sender locked:', isLocked);

// For full job status polling (getJob returns a 14-field struct),
// see the AsyncJobTracker interface in the ritual-dapp-contracts skill.
// Compute expiry as commitBlock + ttl (there is no expiryBlock field).
```

**Fixes**:
- **No services**: Wait for service registration or check TEEServiceRegistry
- **TTL expired**: Increase `ttl` parameter (try 200n or 500n)
- **Executor not responding**: Try a different executor address

#### Executor not found

**Symptoms**: `No services found for capability` error.

**Diagnosis**:
```typescript
// Common capability IDs used by these skills
const capabilityNames: Record<number, string> = {
  0: 'HTTP_CALL',
  1: 'LLM',
  2: 'WORMHOLE_QUERY',
  3: 'STREAMING',
  4: 'VLLM_PROXY',
  5: 'ZK_CALL',
  6: 'DKMS',
  7: 'IMAGE_CALL',
  8: 'AUDIO_CALL',
  9: 'VIDEO_CALL',
  10: 'FHE',
};

for (const cap of Object.keys(capabilityNames).map(Number)) {
  try {
    const services = await publicClient.readContract({
      address: TEE_SERVICE_REGISTRY,
      abi: [{
        name: 'getServicesByCapability',
        type: 'function',
        stateMutability: 'view',
        inputs: [{ name: 'capability', type: 'uint8' }, { name: 'checkValidity', type: 'bool' }],
        outputs: [{ type: 'tuple[]' }],
      }] as const,
      functionName: 'getServicesByCapability',
      args: [cap, true],
    });
    console.log(`${capabilityNames[cap]}: ${services.length} service(s)`);
  } catch (err) {
    console.log(`${capabilityNames[cap]}: unavailable`);
  }
}
```

**Fixes**:
- Verify you're using the correct capability for your precompile
- Confirm the TEEServiceRegistry has registered executors on the network you're targeting

#### Callback not firing

**Symptoms**: Job settles but `onResult` / delivery callback never executes.

**Checklist**:
1. **Delivery target correct?** — The `deliveryTarget` address must be your contract
2. **Delivery selector correct?** — Must match `bytes4(keccak256("onResult(bytes32,bytes)"))`
3. **Gas limit sufficient?** — Callback execution needs gas; try 500,000+
4. **Contract accepts the call?** — The callback function must be `external` (not `internal`/`private`)
5. **No revert in callback?** — If callback reverts, delivery marks as failed

```typescript
import { encodeFunctionData, keccak256, toHex } from 'viem';

// Verify your selector matches
const expectedSelector = keccak256(
  toHex('onResult(bytes32,bytes)')
).slice(0, 10); // first 4 bytes
console.log('Expected selector:', expectedSelector);

// Common selectors:
// handleHTTPResponse(bytes)     → 0x... (calculate for your function)
// onResult(bytes32,bytes)       → 0x... (calculate for your function)
```

#### Insufficient balance

**Symptoms**: Transaction reverts with "insufficient balance" or "deposit required".

**Diagnosis**:
```typescript
import { parseEther, formatEther, type Address } from 'viem';

const RITUAL_WALLET: Address = '0x532F0dF0896F353d8C3DD8cc134e8129DA2a3948';
const walletAbi = [
  { name: 'balanceOf', type: 'function', stateMutability: 'view',
    inputs: [{ name: 'user', type: 'address' }], outputs: [{ type: 'uint256' }] },
  { name: 'deposit', type: 'function', stateMutability: 'payable',
    inputs: [{ name: 'lockDuration', type: 'uint256' }], outputs: [] },
] as const;

const userAddress = walletClient.account.address;

// Check RitualWallet balance
const balance = await publicClient.readContract({
  address: RITUAL_WALLET,
  abi: walletAbi,
  functionName: 'balanceOf',
  args: [userAddress],
});
console.log('Wallet balance:', formatEther(balance), 'RITUAL');

// Check native balance
const nativeBalance = await publicClient.getBalance({ address: userAddress });
console.log('Native balance:', formatEther(nativeBalance), 'RITUAL');

// Deposit if needed
if (balance < parseEther('0.01')) {
  console.log('Depositing 0.05 RITUAL...');
  const hash = await walletClient.writeContract({
    address: RITUAL_WALLET,
    abi: walletAbi,
    functionName: 'deposit',
    args: [5000n],
    value: parseEther('0.05'),
  });
  await publicClient.waitForTransactionReceipt({ hash });
}
```

#### Wrong result format

**Symptoms**: Decoded result is garbage, wrong types, or throws decoding error.

**Checklist**:
1. Ensure you're using the correct codec for the precompile type
2. Check that your Solidity `abi.decode` matches the precompile's output ABI
3. For HTTP responses: body is `bytes`, not `string` — cast if needed

```typescript
import { decodeAbiParameters, type Hex } from 'viem';

// HTTP precompile (0x0801) response format
const [statusCode, headerKeys, headerValues, body, errorMessage] =
  decodeAbiParameters(
    [{ type: 'uint16' }, { type: 'string[]' }, { type: 'string[]' }, { type: 'bytes' }, { type: 'string' }],
    resultHex as Hex
  );

// Common mistake: trying to JSON.parse raw bytes
// Wrong:
const bad = JSON.parse(resultHex); // ❌

// Correct: decode via ABI, then parse the body bytes
const textBody = new TextDecoder().decode(body);
const data = JSON.parse(textBody); // ✅ properly decoded
```

#### Tracing stuck transactions

Use `debug_traceTransaction` with the `callTracer` to see exactly what happened inside a transaction:

```bash
cast rpc debug_traceTransaction <TX_HASH> '{"tracer": "callTracer"}' --rpc-url https://rpc.ritualfoundation.org
```

This returns the full call tree — precompile calls, internal calls, reverts with reason strings. Useful for diagnosing why an async job was rejected or why a callback failed.

---

## 8. Common Error Codes and Fixes

| Error | Cause | Fix |
|-------|-------|-----|
| `No services found for capability` | No TEE services registered for this precompile type | Check TEEServiceRegistry; use correct capability ID |
| `Precompile call failed` | call to precompile address reverted | Check input encoding matches precompile ABI |
| `Insufficient deposit` | RitualWallet balance too low | Call `ritualWalletHelper.deposit()` before request |
| `Job expired` | TTL too short; executor didn't settle in time | Increase `ttl` parameter |
| `Unauthorized delivery` | Callback sender isn't the expected delivery address | Verify delivery address in contract constructor |
| `Unknown job` | Callback for a job ID that doesn't exist in your mapping | Ensure job was properly registered in `submitJob` |
| `Input too large` | Encoded request exceeds 10KB async input limit | Reduce request size; move data off-chain |
| `Executor timeout` | Executor didn't respond within the execution window | Retry with different executor or higher TTL |
| `Invalid secret signature` | Secret signature doesn't match encrypted payload | Re-sign with correct private key |
| `Decoding error` | ABI mismatch between encoder and decoder | Verify codec type matches precompile |
| `Transaction reverted without reason` | Contract logic error or insufficient gas | Increase gas limit; check contract with `forge test -vvvv` |
| `Nonce too low` | Concurrent transactions from same account | Wait for pending tx or use nonce manager |

---

## 9. Environment & Run Commands

Ritual Chain (ID 1979, testnet).

```bash
RITUAL_RPC_URL=https://rpc.ritualfoundation.org
RITUAL_WS_URL=wss://rpc.ritualfoundation.org/ws
```

| Test type | Command |
|-----------|---------|
| Solidity unit tests | `forge test --no-match-contract Fork -vvv` |
| Solidity fork tests | `RITUAL_RPC_URL=... forge test --match-contract Fork -vvv` |
| Fuzz tests | `forge test --match-test testFuzz -vvv` |
| Gas snapshots | `forge snapshot --check` |
| TypeScript unit tests | `npx vitest run` |
| Integration tests (on-chain) | `npx vitest run --config vitest.integration.config.ts` |

For integration tests, set `maxConcurrency: 1` and `testTimeout: 120_000` to serialize on-chain transactions and allow settlement time.

---

## 11. Test Utilities and Helpers

### Shared Test Fixtures

```typescript
// test/fixtures.ts
import type { Address, Hex } from 'viem';

export const TEST_EXECUTOR: Address = '0x1234567890abcdef1234567890abcdef12345678';
export const TEST_USER: Address = '0xabcdefabcdefabcdefabcdefabcdefabcdefabcd';

export const MOCK_HTTP_RESPONSE_SUCCESS = {
  statusCode: 200 as const,
  headers: { 'content-type': 'application/json' },
  body: new TextEncoder().encode('{"result": "ok"}'),
  errorMessage: '',
};

export const MOCK_HTTP_RESPONSE_ERROR = {
  statusCode: 0 as const,
  headers: {},
  body: new Uint8Array(),
  errorMessage: 'executor timeout',
};

export function makeJobId(seed: string): Hex {
  return `0x${Buffer.from(seed.padEnd(32, '\0')).toString('hex')}` as Hex;
}

export function makeMockHTTPResponseData(
  status: number,
  body: string,
  error = ''
): Hex {
  // Returns ABI-encoded HTTP response data for testing short-running async settlement decoding
  const { encodeAbiParameters } = require('viem');
  return encodeAbiParameters(
    [
      { type: 'uint16' },
      { type: 'string[]' },
      { type: 'string[]' },
      { type: 'bytes' },
      { type: 'string' },
    ],
    [status, [], [], new TextEncoder().encode(body), error]
  );
}
```

### Test Timeouts and Retries

```typescript
// test/helpers.ts
export async function waitForCondition(
  check: () => Promise<boolean>,
  timeoutMs = 60_000,
  pollMs = 2000
): Promise<void> {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    if (await check()) return;
    await new Promise((r) => setTimeout(r, pollMs));
  }
  throw new Error(`Condition not met within ${timeoutMs}ms`);
}

export async function retryAsync<T>(
  fn: () => Promise<T>,
  retries = 3,
  delayMs = 1000
): Promise<T> {
  let lastError: Error | undefined;
  for (let i = 0; i < retries; i++) {
    try {
      return await fn();
    } catch (err) {
      lastError = err as Error;
      if (i < retries - 1) {
        await new Promise((r) => setTimeout(r, delayMs * (i + 1)));
      }
    }
  }
  throw lastError;
}
```

---

## Quick Reference

| Item | Value |
|------|-------|
| Foundry test command | `forge test -vvv` |
| Fork test command | `RITUAL_RPC_URL=... forge test --match-contract Fork -vvv` |
| Fuzz test command | `forge test --match-test testFuzz -vvv` |
| viem/unit tests | `npx vitest run` |
| Integration tests | `npx vitest run --config vitest.integration.config.ts` |
| Gas snapshot | `forge snapshot` |
| Coverage | `forge coverage` |
| Mock precompile | `vm.mockCall(address(0x0801), "", responseBytes)` |
| Etch precompile | `vm.etch(address(0x0801), mockContract.code)` |
| AsyncJobTracker | `0xC069FFCa0389f44eCA2C626e55491b0ab045AEF5` |
| TEEServiceRegistry | `0x9644e8562cE0Fe12b4deeC4163c064A8862Bf47F` |
| RitualWallet | `0x532F0dF0896F353d8C3DD8cc134e8129DA2a3948` |
| Chain ID | 1979 |
| ABI encoding | `encodeAbiParameters` / `decodeAbiParameters` from viem |
| Executor query | `publicClient.readContract({ address: TEE_SERVICE_REGISTRY, ... })` |
| DA providers | Test with GCS (default), HuggingFace, and Pinata — see `ritual-dapp-da` for StorageRef format |
