# Test Plan — AIJudgeCommitReveal

All cases below are implemented and passing in `test/AIJudgeCommitReveal.test.js` (11 tests). The Ritual LLM precompile at `0x…0802` is mocked locally with `setCode` so `judgeAll()` runs end-to-end.

**Happy path.** Two participants commit; during the commit phase `getSubmission` shows `revealed = false` and an empty answer string (nothing readable on-chain). Both reveal in the reveal window, `getRevealedAnswers` returns both answers with original indices, the owner batch-judges after the reveal deadline, the AI review is stored, and finalizing pays exactly the full reward to the winner's address (balance-checked).

**Valid vs invalid reveals (core of the homework).**
1. Reveal with the correct answer + salt + sender → accepted.
2. Correct answer, wrong salt → `commitment mismatch`.
3. Wrong answer, correct salt → `commitment mismatch`.
4. Copied commitment: an attacker submits a byte-identical copy of a victim's commitment, waits for the victim to reveal (answer now public), then tries to reveal the same answer + salt → `commitment mismatch`, because `msg.sender` is bound into the hash. This is the exact attack the homework asks us to prevent.
5. Reveal without ever committing → `no commitment`.
6. Reveal before the submission deadline → `reveal not started`.
7. Reveal after the reveal deadline → `reveal phase over`.

**Phase and access control.**
8. Commit after the submission deadline → `commit phase over`.
9. Second commitment from the same address → `already committed`.
10. `judgeAll` before the reveal deadline → `reveal phase not over`; by a non-owner → `not bounty owner`.
11. `createBounty` with a past submission deadline or a reveal deadline before the submission deadline → reverts.

**Payout safety.**
12. `finalizeWinner` pointing at an unrevealed submission → `winner not revealed`; the revealed submission can still win.
13. Nobody reveals: `judgeAll` reverts with `no revealed answers`, and `cancelBounty` refunds the owner after the reveal deadline (and is blocked while the reveal window is still open), so funds can never be locked forever.

Manual testnet check (Ritual, chain 1979): deploy, create a bounty with short deadlines, commit from two wallets, reveal from both, call `judgeAll` with a real batch prompt built from `getRevealedAnswers`, confirm the verdict lands in `aiReview`, finalize, and confirm the RITUAL transfer on the explorer.
