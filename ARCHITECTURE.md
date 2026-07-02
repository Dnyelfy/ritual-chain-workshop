# Architecture Note — Commit-Reveal vs Ritual-Native Encrypted Submissions

## What commit-reveal actually buys you

Commit-reveal is chain-agnostic and cheap. During the submission phase the chain holds only 32-byte hashes, so no participant can read or copy anyone's answer while submissions are open. The commitment binds `msg.sender` and `bountyId` into the hash, which kills the copy-the-hash attack: a stolen commitment can never be revealed by anyone but its author.

But it has two honest limitations. First, **answers become public before AI judging happens** — between the reveal deadline and the `judgeAll()` call, every revealed answer sits in plaintext storage. This is fine for a bounty (submissions are already locked), but it is not true privacy through the judging step. Second, it needs **participant liveness**: everyone must come back during the reveal window and send a second transaction, or their submission is silently disqualified.

## Ritual-native design (Advanced Track)

Ritual's execution model removes both limitations, because the chain can run AI over data that the public never sees.

```
 Participant browser                      Ritual chain                    TEE executor
 ─────────────────────                   ─────────────                   ─────────────
 answer (plaintext)                                                       
   │  encrypt to TEE key                                                  
   ▼                                                                      
 ciphertext ──► off-chain store          submitEncrypted(               
 (or small ct on-chain)                    ctRef, ctHash)  ──────┐       
                                         stores ref + hash       │       
                                                                 ▼       
                                         judgeAll() ──► LLM precompile   
                                                         0x0802 with     
                                                         private inputs ─► decrypt ALL
                                                                            ciphertexts
                                                                            inside enclave
                                                                            │
                                                                            ▼
                                                                          ONE batch prompt
                                                                          (rubric + all
                                                                           answers) ► LLM
                                                                            │
                                         verdict JSON + bundle ◄───────────┘
                                         revealedAnswersRef
                                         revealedAnswersHash
```

**Where plaintext exists and who can read it.** Exactly two places: the participant's own browser at typing time, and inside the TEE enclave during judging. The bounty owner, other participants, RPC nodes, and explorers see only ciphertext until judging is complete. This is the key difference from commit-reveal, where the owner and everyone else sees plaintext during the reveal window.

**On-chain vs off-chain.** On-chain: the bounty (rubric, reward, deadlines), per-submission `ciphertextHash` plus a storage reference `ciphertextRef`, the AI verdict, and after judging a `revealedAnswersRef` + `revealedAnswersHash` pair. Off-chain: the ciphertexts themselves (IPFS or Ritual-accessible storage) and, after judging, the revealed answer bundle. Storing full plaintext answers on-chain would cost roughly 20k gas per 32 bytes of SSTORE; a hash commitment to an off-chain bundle gives the same verifiability for a flat 32 bytes.

**Encryption and secrets.** Participants encrypt to a key managed through Ritual's key-management flow (DKMS precompile `0x081B` / encrypted secrets), so the decryption key is available only inside attested TEE execution. Storage credentials, if any, travel as encrypted secrets referenced by name — never plaintext on-chain.

**How the LLM receives submissions.** `judgeAll()` triggers one LLM inference request whose private inputs reference all ciphertexts. The TEE decrypts them inside the enclave, assembles a single prompt — rubric followed by the numbered answers — and makes **one** batch inference. One call per answer would be slower, more expensive, and would let the judge score answers without cross-comparison; batch judging is both cheaper and fairer.

**Final reveal and verification.** After the verdict, the TEE publishes the full answer bundle off-chain and the contract stores its keccak256 hash next to the reference. Anyone can download the bundle, hash it, and confirm it matches — the contract has committed to exactly one revealed history. Losing participants can verify their answer appears unmodified in the judged set.

**What the AI output looks like.**

```json
{
  "winnerIndex": 2,
  "ranking": [{ "index": 2, "score": 94, "reason": "Best satisfies the rubric." }],
  "revealedAnswersRef": "ipfs://…",
  "revealedAnswersHash": "0x…",
  "summary": "Submission 2 is the strongest answer."
}
```

The contract never auto-pays from this output. The verdict is parsed and displayed off-chain, and the owner finalizes with an explicit `finalizeWinner()` — AI recommends, a human is accountable for the money moving.

## Trade-off summary

Commit-reveal: works on every EVM chain, no trust assumptions beyond the hash function, but requires a second transaction from every participant and exposes answers before judging. Ritual-native: answers stay hidden through judging itself, single participant transaction, no reveal-liveness failure mode — at the cost of trusting TEE attestation and running Ritual-specific infrastructure. For a Ritual-deployed bounty app, the native design is strictly better UX; commit-reveal remains the right portable baseline, which is why this submission implements commit-reveal fully and specifies the Ritual-native flow as the upgrade path.
