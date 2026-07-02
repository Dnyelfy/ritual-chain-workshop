# Privacy-Preserving AI Bounty Judge — Commit-Reveal

Homework submission for the Ritual AI Bounty Judge workshop.
Builder: Dönay ([@Dnyelfy](https://x.com/Dnyelfy) · dnyelf.base.eth · `0x15DC3C8131a351F307Ca5eB04d227EA0Fe01ac71`)

## The problem

In the workshop version, `submitAnswer(bountyId, string answer)` stores the plaintext answer on-chain the moment it is submitted. Anyone can call `getSubmission()` (or just read calldata in the explorer), copy an earlier participant's idea, improve it slightly, and submit a "better" version. In a winner-takes-all bounty this breaks fairness completely.

## The fix: commit-reveal

`AIJudgeCommitReveal.sol` splits submission into two phases so no answer is readable while submissions are still open.

```
CREATE ──► COMMIT ──────────► REVEAL ─────────► JUDGE ──► FINALIZE
           (only hashes       (answer + salt    (one batch (human picks
            on-chain)          verified against  LLM call)  the winner,
                               the hash)                    reward paid)
        submissionDeadline  revealDeadline
```

### 1. Create

The owner funds the bounty and sets two deadlines:

```solidity
createBounty(title, rubric, submissionDeadline, revealDeadline)
```

`revealDeadline` must be after `submissionDeadline`.

### 2. Commit phase (`now < submissionDeadline`)

Participants compute a commitment locally and submit only the hash:

```solidity
bytes32 commitment = keccak256(
    abi.encodePacked(answer, salt, msg.sender, bountyId)
);
submitCommitment(bountyId, commitment);
```

Because `msg.sender` and `bountyId` are inside the hash, copying someone else's on-chain commitment is useless: the copier can never produce a matching reveal (covered by a dedicated test). One commitment per address, max 10 per bounty, empty hashes rejected. The plaintext answer never leaves the participant's machine in this phase.

### 3. Reveal phase (`submissionDeadline <= now < revealDeadline`)

Each participant submits the real answer and salt. The contract recomputes the hash with `msg.sender` and `bountyId` and accepts the answer only on an exact match. Wrong salt, wrong answer, wrong sender, double reveals, and out-of-window reveals all revert. Unrevealed commitments simply stay sealed forever.

### 4. Judge phase (`now >= revealDeadline`)

The owner calls `judgeAll(bountyId, llmInput)`. The frontend builds `llmInput` from the rubric plus `getRevealedAnswers(bountyId)` — all revealed answers go into **one** Ritual LLM inference call (precompile `0x0802`), never one call per answer. The AI's verdict is stored in `aiReview`.

### 5. Finalize

`finalizeWinner(bountyId, winnerIndex)` is human-in-the-loop: the AI recommends, the owner decides. The contract enforces that the winner index points to a *revealed* submission, zeroes the reward before transferring (checks-effects-interactions), and pays exactly one winner. If nobody revealed, `cancelBounty()` lets the owner reclaim the reward after the reveal deadline instead of locking funds forever.

## Contract rules enforced

Commit only before `submissionDeadline` · reveal only inside the reveal window · one commitment per participant · reveal valid only on exact hash match · unrevealed submissions ineligible for judging and payout · judging only after `revealDeadline` and only by the owner · finalize only after judging · exactly one winner is paid.

## Files

```
contracts/AIJudgeCommitReveal.sol      the commit-reveal contract
contracts/test/MockLLMPrecompile.sol   test-only mock of Ritual precompile 0x0802
test/AIJudgeCommitReveal.test.js       11 tests (see TEST-PLAN.md)
ARCHITECTURE.md                        commit-reveal vs Ritual-native TEE design
REFLECTION.md                          reflection question answer
```

## Running the tests

```bash
npm install
npx hardhat test
# 11 passing
```

The tests place a mock of the LLM inference precompile at `0x…0802` via `setCode`, so the full lifecycle — including `judgeAll` and the stored AI review — runs locally on any EVM test node. On Ritual testnet (chain 1979) the same call hits the real TEE-backed LLM precompile.
