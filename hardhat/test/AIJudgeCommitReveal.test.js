import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { network } from "hardhat";
import { encodePacked, keccak256, parseEther } from "viem";

// Ritual's LLM inference precompile address (mocked locally via setCode).
const LLM_PRECOMPILE = "0x0000000000000000000000000000000000000802";

const SALT_A =
  "0x1111111111111111111111111111111111111111111111111111111111111111";
const SALT_B =
  "0x2222222222222222222222222222222222222222222222222222222222222222";

function commitmentFor(answer, salt, sender, bountyId) {
  return keccak256(
    encodePacked(
      ["string", "bytes32", "address", "uint256"],
      [answer, salt, sender, bountyId],
    ),
  );
}

describe("AIJudgeCommitReveal", async () => {
  const { viem, networkHelpers } = await network.connect();

  async function setup() {
    const [owner, alice, bob, mallory] = await viem.getWalletClients();
    const publicClient = await viem.getPublicClient();

    const judge = await viem.deployContract("AIJudgeCommitReveal");

    // Install the mock LLM precompile at 0x0802.
    const mock = await viem.deployContract("MockLLMPrecompile");
    const mockCode = await publicClient.getCode({ address: mock.address });
    await networkHelpers.setCode(LLM_PRECOMPILE, mockCode);

    const now = BigInt(await networkHelpers.time.latest());
    const submissionDeadline = now + 1000n;
    const revealDeadline = now + 2000n;

    await judge.write.createBounty(
      ["Best slogan", "Judge by clarity and originality", submissionDeadline, revealDeadline],
      { value: parseEther("1"), account: owner.account },
    );
    const bountyId = 1n;

    return {
      judge, publicClient, networkHelpers,
      owner, alice, bob, mallory,
      bountyId, submissionDeadline, revealDeadline,
    };
  }

  it("runs the full lifecycle: commit -> reveal -> judge -> finalize + payout", async () => {
    const s = await setup();

    const answerA = "Privacy is the product.";
    const answerB = "Hide it until you judge it.";

    const cA = commitmentFor(answerA, SALT_A, s.alice.account.address, s.bountyId);
    const cB = commitmentFor(answerB, SALT_B, s.bob.account.address, s.bountyId);

    await s.judge.write.submitCommitment([s.bountyId, cA], { account: s.alice.account });
    await s.judge.write.submitCommitment([s.bountyId, cB], { account: s.bob.account });

    // Answers are NOT on-chain during the commit phase.
    let sub0 = await s.judge.read.getSubmission([s.bountyId, 0n]);
    assert.equal(sub0[2], false); // revealed
    assert.equal(sub0[3], "");   // answer empty

    // Enter reveal phase.
    await s.networkHelpers.time.increaseTo(s.submissionDeadline);

    await s.judge.write.revealAnswer([s.bountyId, answerA, SALT_A], { account: s.alice.account });
    await s.judge.write.revealAnswer([s.bountyId, answerB, SALT_B], { account: s.bob.account });

    const [indices, answers] = await s.judge.read.getRevealedAnswers([s.bountyId]);
    assert.deepEqual(indices, [0n, 1n]);
    assert.deepEqual(answers, [answerA, answerB]);

    // Enter judge phase; ONE batch LLM call.
    await s.networkHelpers.time.increaseTo(s.revealDeadline);
    await s.judge.write.judgeAll([s.bountyId, "0x1234"], { account: s.owner.account });

    const bounty = await s.judge.read.getBounty([s.bountyId]);
    assert.equal(bounty.judged, true);
    assert.ok(bounty.aiReview.length > 2, "aiReview stored");

    // Owner finalizes Bob (index 1) as winner; reward is paid out.
    const before = await s.publicClient.getBalance({ address: s.bob.account.address });
    await s.judge.write.finalizeWinner([s.bountyId, 1n], { account: s.owner.account });
    const after = await s.publicClient.getBalance({ address: s.bob.account.address });

    assert.equal(after - before, parseEther("1"));
  });

  it("rejects commitments after the submission deadline", async () => {
    const s = await setup();
    await s.networkHelpers.time.increaseTo(s.submissionDeadline);

    const c = commitmentFor("late", SALT_A, s.alice.account.address, s.bountyId);
    await assert.rejects(
      s.judge.write.submitCommitment([s.bountyId, c], { account: s.alice.account }),
      /commit phase over/,
    );
  });

  it("allows only one commitment per participant", async () => {
    const s = await setup();
    const c = commitmentFor("one", SALT_A, s.alice.account.address, s.bountyId);

    await s.judge.write.submitCommitment([s.bountyId, c], { account: s.alice.account });
    await assert.rejects(
      s.judge.write.submitCommitment([s.bountyId, c], { account: s.alice.account }),
      /already committed/,
    );
  });

  it("rejects reveals during the commit phase", async () => {
    const s = await setup();
    const c = commitmentFor("early", SALT_A, s.alice.account.address, s.bountyId);
    await s.judge.write.submitCommitment([s.bountyId, c], { account: s.alice.account });

    await assert.rejects(
      s.judge.write.revealAnswer([s.bountyId, "early", SALT_A], { account: s.alice.account }),
      /reveal not started/,
    );
  });

  it("rejects reveals with a wrong salt or wrong answer", async () => {
    const s = await setup();
    const c = commitmentFor("real answer", SALT_A, s.alice.account.address, s.bountyId);
    await s.judge.write.submitCommitment([s.bountyId, c], { account: s.alice.account });
    await s.networkHelpers.time.increaseTo(s.submissionDeadline);

    await assert.rejects(
      s.judge.write.revealAnswer([s.bountyId, "real answer", SALT_B], { account: s.alice.account }),
      /commitment mismatch/,
    );
    await assert.rejects(
      s.judge.write.revealAnswer([s.bountyId, "fake answer", SALT_A], { account: s.alice.account }),
      /commitment mismatch/,
    );
  });

  it("prevents commitment copying: a copied hash can never be revealed", async () => {
    const s = await setup();

    // Alice commits honestly.
    const cAlice = commitmentFor("original idea", SALT_A, s.alice.account.address, s.bountyId);
    await s.judge.write.submitCommitment([s.bountyId, cAlice], { account: s.alice.account });

    // Mallory copies Alice's on-chain commitment byte-for-byte.
    await s.judge.write.submitCommitment([s.bountyId, cAlice], { account: s.mallory.account });

    await s.networkHelpers.time.increaseTo(s.submissionDeadline);

    // Alice reveals fine; the answer becomes public...
    await s.judge.write.revealAnswer([s.bountyId, "original idea", SALT_A], { account: s.alice.account });

    // ...but Mallory still cannot reveal it: the hash binds msg.sender.
    await assert.rejects(
      s.judge.write.revealAnswer([s.bountyId, "original idea", SALT_A], { account: s.mallory.account }),
      /commitment mismatch/,
    );
  });

  it("rejects reveals after the reveal deadline and from non-committers", async () => {
    const s = await setup();
    const c = commitmentFor("slow", SALT_A, s.alice.account.address, s.bountyId);
    await s.judge.write.submitCommitment([s.bountyId, c], { account: s.alice.account });

    await s.networkHelpers.time.increaseTo(s.submissionDeadline);
    await assert.rejects(
      s.judge.write.revealAnswer([s.bountyId, "anything", SALT_A], { account: s.bob.account }),
      /no commitment/,
    );

    await s.networkHelpers.time.increaseTo(s.revealDeadline);
    await assert.rejects(
      s.judge.write.revealAnswer([s.bountyId, "slow", SALT_A], { account: s.alice.account }),
      /reveal phase over/,
    );
  });

  it("blocks judging before the reveal deadline and by non-owners", async () => {
    const s = await setup();
    const c = commitmentFor("x", SALT_A, s.alice.account.address, s.bountyId);
    await s.judge.write.submitCommitment([s.bountyId, c], { account: s.alice.account });

    await s.networkHelpers.time.increaseTo(s.submissionDeadline);
    await s.judge.write.revealAnswer([s.bountyId, "x", SALT_A], { account: s.alice.account });

    await assert.rejects(
      s.judge.write.judgeAll([s.bountyId, "0x1234"], { account: s.owner.account }),
      /reveal phase not over/,
    );

    await s.networkHelpers.time.increaseTo(s.revealDeadline);
    await assert.rejects(
      s.judge.write.judgeAll([s.bountyId, "0x1234"], { account: s.alice.account }),
      /not bounty owner/,
    );
  });

  it("never pays an unrevealed submission", async () => {
    const s = await setup();

    const cA = commitmentFor("revealed", SALT_A, s.alice.account.address, s.bountyId);
    const cB = commitmentFor("ghost", SALT_B, s.bob.account.address, s.bountyId);
    await s.judge.write.submitCommitment([s.bountyId, cA], { account: s.alice.account });
    await s.judge.write.submitCommitment([s.bountyId, cB], { account: s.bob.account });

    await s.networkHelpers.time.increaseTo(s.submissionDeadline);
    await s.judge.write.revealAnswer([s.bountyId, "revealed", SALT_A], { account: s.alice.account });
    // Bob never reveals.

    await s.networkHelpers.time.increaseTo(s.revealDeadline);
    await s.judge.write.judgeAll([s.bountyId, "0x1234"], { account: s.owner.account });

    await assert.rejects(
      s.judge.write.finalizeWinner([s.bountyId, 1n], { account: s.owner.account }),
      /winner not revealed/,
    );

    // The revealed submission can win.
    await s.judge.write.finalizeWinner([s.bountyId, 0n], { account: s.owner.account });
  });

  it("lets the owner reclaim the reward if nobody reveals", async () => {
    const s = await setup();

    const c = commitmentFor("never", SALT_A, s.alice.account.address, s.bountyId);
    await s.judge.write.submitCommitment([s.bountyId, c], { account: s.alice.account });

    // Cannot cancel while the reveal window is still open.
    await s.networkHelpers.time.increaseTo(s.submissionDeadline);
    await assert.rejects(
      s.judge.write.cancelBounty([s.bountyId], { account: s.owner.account }),
      /reveal phase not over/,
    );

    await s.networkHelpers.time.increaseTo(s.revealDeadline);

    // Judging with zero reveals is impossible...
    await assert.rejects(
      s.judge.write.judgeAll([s.bountyId, "0x1234"], { account: s.owner.account }),
      /no revealed answers/,
    );

    // ...so the owner reclaims the reward instead.
    await s.judge.write.cancelBounty([s.bountyId], { account: s.owner.account });
    const bounty = await s.judge.read.getBounty([s.bountyId]);
    assert.equal(bounty.finalized, true);
    assert.equal(bounty.reward, 0n);
  });

  it("validates bounty creation deadlines", async () => {
    const s = await setup();
    const now = BigInt(await s.networkHelpers.time.latest());

    await assert.rejects(
      s.judge.write.createBounty(["t", "r", now - 1n, now + 100n], {
        value: parseEther("0.1"), account: s.owner.account,
      }),
      /submission deadline in past/,
    );
    await assert.rejects(
      s.judge.write.createBounty(["t", "r", now + 200n, now + 100n], {
        value: parseEther("0.1"), account: s.owner.account,
      }),
      /reveal must follow submission/,
    );
  });
});
