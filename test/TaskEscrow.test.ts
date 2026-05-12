import { expect } from 'chai';
import { ethers } from 'hardhat';
import { loadFixture } from '@nomicfoundation/hardhat-toolbox/network-helpers';
import { TaskEscrow } from '../typechain-types';

describe('TaskEscrow', () => {
  async function deployFixture() {
    const [owner, client, freelancer, feeRecipient, other] = await ethers.getSigners();
    const TaskEscrow = await ethers.getContractFactory('TaskEscrow');
    const contract = (await TaskEscrow.deploy(feeRecipient.address)) as TaskEscrow;
    return { contract, owner, client, freelancer, feeRecipient, other };
  }

  const TASK_ID = 'aabbccdd1122334455667788'; // 24-char MongoDB ObjectId
  const TASK_ID2 = 'aabbccdd112233445566aabb';
  const PRICE = ethers.parseEther('1.0');

  // ─── helpers ───────────────────────────────────────────────────────────

  async function funded(contract: TaskEscrow, client: any) {
    await contract.connect(client).fundTask(TASK_ID, { value: PRICE });
  }

  async function inProgress(contract: TaskEscrow, client: any, freelancer: any) {
    await funded(contract, client);
    await contract.connect(client).assignFreelancer(TASK_ID, freelancer.address);
  }

  async function workSubmitted(contract: TaskEscrow, client: any, freelancer: any) {
    await inProgress(contract, client, freelancer);
    await contract.connect(freelancer).submitWork(TASK_ID);
  }

  // ─── deployment ────────────────────────────────────────────────────────

  describe('Deployment', () => {
    it('Sets fee recipient', async () => {
      const { contract, feeRecipient } = await loadFixture(deployFixture);
      expect(await contract.feeRecipient()).to.equal(feeRecipient.address);
    });

    it('Sets default fee to 2.5%', async () => {
      const { contract } = await loadFixture(deployFixture);
      expect(await contract.feeBasisPoints()).to.equal(250);
    });

    it('Rejects zero address fee recipient', async () => {
      const TaskEscrow = await ethers.getContractFactory('TaskEscrow');
      await expect(TaskEscrow.deploy(ethers.ZeroAddress))
        .to.be.revertedWithCustomError(TaskEscrow, 'ZeroAddress');
    });

    it('Rejects direct ETH sends', async () => {
      const { contract, other } = await loadFixture(deployFixture);
      await expect(
        other.sendTransaction({ to: await contract.getAddress(), value: PRICE }),
      ).to.be.reverted;
    });
  });

  // ─── fundTask ───────────────────────────────────────────────────────────

  describe('fundTask', () => {
    it('Creates task and emits event', async () => {
      const { contract, client } = await loadFixture(deployFixture);
      const key = ethers.keccak256(ethers.AbiCoder.defaultAbiCoder().encode(
        ['string'], [TASK_ID],
      ));
      await expect(contract.connect(client).fundTask(TASK_ID, { value: PRICE }))
        .to.emit(contract, 'TaskFunded')
        .withArgs(key, TASK_ID, client.address, PRICE);

      const task = await contract.getTask(TASK_ID);
      expect(task.client).to.equal(client.address);
      expect(task.amount).to.equal(PRICE);
      expect(task.state).to.equal(1); // Funded
    });

    it('Reverts on zero value', async () => {
      const { contract, client } = await loadFixture(deployFixture);
      await expect(contract.connect(client).fundTask(TASK_ID, { value: 0 }))
        .to.be.revertedWithCustomError(contract, 'ZeroValue');
    });

    it('Reverts on duplicate task ID', async () => {
      const { contract, client } = await loadFixture(deployFixture);
      await funded(contract, client);
      await expect(contract.connect(client).fundTask(TASK_ID, { value: PRICE }))
        .to.be.revertedWithCustomError(contract, 'TaskExists');
    });

    it('Reverts on empty task ID', async () => {
      const { contract, client } = await loadFixture(deployFixture);
      await expect(contract.connect(client).fundTask('', { value: PRICE }))
        .to.be.revertedWithCustomError(contract, 'TaskIdTooLong');
    });

    it('Reverts on task ID longer than 64 chars', async () => {
      const { contract, client } = await loadFixture(deployFixture);
      const longId = 'a'.repeat(65);
      await expect(contract.connect(client).fundTask(longId, { value: PRICE }))
        .to.be.revertedWithCustomError(contract, 'TaskIdTooLong');
    });
  });

  // ─── assignFreelancer ───────────────────────────────────────────────────

  describe('assignFreelancer', () => {
    it('Assigns freelancer and moves to InProgress', async () => {
      const { contract, client, freelancer } = await loadFixture(deployFixture);
      await funded(contract, client);
      await contract.connect(client).assignFreelancer(TASK_ID, freelancer.address);
      const task = await contract.getTask(TASK_ID);
      expect(task.freelancer).to.equal(freelancer.address);
      expect(task.state).to.equal(2); // InProgress
    });

    it('Rejects non-client assignment', async () => {
      const { contract, client, freelancer, other } = await loadFixture(deployFixture);
      await funded(contract, client);
      await expect(
        contract.connect(other).assignFreelancer(TASK_ID, freelancer.address),
      ).to.be.revertedWithCustomError(contract, 'Unauthorized');
    });

    it('Rejects zero address freelancer', async () => {
      const { contract, client } = await loadFixture(deployFixture);
      await funded(contract, client);
      await expect(
        contract.connect(client).assignFreelancer(TASK_ID, ethers.ZeroAddress),
      ).to.be.revertedWithCustomError(contract, 'ZeroAddress');
    });

    it('Rejects self-assignment', async () => {
      const { contract, client } = await loadFixture(deployFixture);
      await funded(contract, client);
      await expect(
        contract.connect(client).assignFreelancer(TASK_ID, client.address),
      ).to.be.revertedWithCustomError(contract, 'SelfAssignment');
    });
  });

  // ─── submitWork ─────────────────────────────────────────────────────────

  describe('submitWork', () => {
    it('Freelancer submits work', async () => {
      const { contract, client, freelancer } = await loadFixture(deployFixture);
      await inProgress(contract, client, freelancer);
      await expect(contract.connect(freelancer).submitWork(TASK_ID))
        .to.emit(contract, 'WorkSubmitted');
      const task = await contract.getTask(TASK_ID);
      expect(task.state).to.equal(3); // WorkSubmitted
    });

    it('Rejects non-freelancer', async () => {
      const { contract, client, freelancer, other } = await loadFixture(deployFixture);
      await inProgress(contract, client, freelancer);
      await expect(contract.connect(other).submitWork(TASK_ID))
        .to.be.revertedWithCustomError(contract, 'Unauthorized');
    });
  });

  // ─── approveWork ────────────────────────────────────────────────────────

  describe('approveWork', () => {
    it('Distributes funds correctly (2.5% fee)', async () => {
      const { contract, client, freelancer, feeRecipient } = await loadFixture(deployFixture);
      await workSubmitted(contract, client, freelancer);

      const freelancerBefore = await ethers.provider.getBalance(freelancer.address);
      const tx = await contract.connect(client).approveWork(TASK_ID);
      const receipt = await tx.wait();

      const freelancerAfter = await ethers.provider.getBalance(freelancer.address);

      const expectedFee = (PRICE * 250n) / 10_000n;
      const expectedPayout = PRICE - expectedFee;

      expect(freelancerAfter - freelancerBefore).to.equal(expectedPayout);

      // Fee goes to pendingWithdrawals, not directly
      expect(await contract.pendingWithdrawals(feeRecipient.address)).to.equal(expectedFee);

      const task = await contract.getTask(TASK_ID);
      expect(task.state).to.equal(4);  // Completed
      expect(task.amount).to.equal(0); // Zeroed
    });

    it('Rejects non-client', async () => {
      const { contract, client, freelancer, other } = await loadFixture(deployFixture);
      await workSubmitted(contract, client, freelancer);
      await expect(contract.connect(other).approveWork(TASK_ID))
        .to.be.revertedWithCustomError(contract, 'Unauthorized');
    });

    it('Rejects approving before work submitted', async () => {
      const { contract, client, freelancer } = await loadFixture(deployFixture);
      await inProgress(contract, client, freelancer);
      await expect(contract.connect(client).approveWork(TASK_ID))
        .to.be.revertedWithCustomError(contract, 'InvalidState');
    });
  });

  // ─── cancelTask ─────────────────────────────────────────────────────────

  describe('cancelTask', () => {
    it('Refunds client when task is Funded', async () => {
      const { contract, client } = await loadFixture(deployFixture);
      await funded(contract, client);

      const before = await ethers.provider.getBalance(client.address);
      const tx = await contract.connect(client).cancelTask(TASK_ID);
      const receipt = await tx.wait();
      const gasUsed = receipt!.gasUsed * tx.gasPrice!;
      const after = await ethers.provider.getBalance(client.address);

      expect(after).to.be.closeTo(before + PRICE - gasUsed, ethers.parseEther('0.0001'));
    });

    it('Refunds client when task is InProgress', async () => {
      const { contract, client, freelancer } = await loadFixture(deployFixture);
      await inProgress(contract, client, freelancer);
      const before = await ethers.provider.getBalance(client.address);
      const tx = await contract.connect(client).cancelTask(TASK_ID);
      const receipt = await tx.wait();
      const gasUsed = receipt!.gasUsed * tx.gasPrice!;
      const after = await ethers.provider.getBalance(client.address);
      expect(after).to.be.closeTo(before + PRICE - gasUsed, ethers.parseEther('0.0001'));
    });

    it('Reverts cancelling after work submitted', async () => {
      const { contract, client, freelancer } = await loadFixture(deployFixture);
      await workSubmitted(contract, client, freelancer);
      await expect(contract.connect(client).cancelTask(TASK_ID))
        .to.be.revertedWithCustomError(contract, 'InvalidState');
    });
  });

  // ─── dispute ────────────────────────────────────────────────────────────

  describe('raiseDispute / resolveDispute', () => {
    it('Client raises dispute', async () => {
      const { contract, client, freelancer } = await loadFixture(deployFixture);
      await workSubmitted(contract, client, freelancer);
      await contract.connect(client).raiseDispute(TASK_ID);
      expect((await contract.getTask(TASK_ID)).state).to.equal(6); // Disputed
    });

    it('Freelancer raises dispute', async () => {
      const { contract, client, freelancer } = await loadFixture(deployFixture);
      await workSubmitted(contract, client, freelancer);
      await contract.connect(freelancer).raiseDispute(TASK_ID);
      expect((await contract.getTask(TASK_ID)).state).to.equal(6);
    });

    it('Third party cannot raise dispute', async () => {
      const { contract, client, freelancer, other } = await loadFixture(deployFixture);
      await workSubmitted(contract, client, freelancer);
      await expect(contract.connect(other).raiseDispute(TASK_ID))
        .to.be.revertedWithCustomError(contract, 'Unauthorized');
    });

    it('resolveDispute(true) — pays freelancer with fee', async () => {
      const { contract, owner, client, freelancer, feeRecipient } = await loadFixture(deployFixture);
      await workSubmitted(contract, client, freelancer);
      await contract.connect(client).raiseDispute(TASK_ID);

      const before = await ethers.provider.getBalance(freelancer.address);
      await contract.connect(owner).resolveDispute(TASK_ID, true);
      const after = await ethers.provider.getBalance(freelancer.address);

      const fee = (PRICE * 250n) / 10_000n;
      const payout = PRICE - fee;
      expect(after - before).to.equal(payout);
      expect(await contract.pendingWithdrawals(feeRecipient.address)).to.equal(fee);
    });

    it('resolveDispute(false) — full refund to client, zero fee', async () => {
      const { contract, owner, client, freelancer, feeRecipient } = await loadFixture(deployFixture);
      await workSubmitted(contract, client, freelancer);
      await contract.connect(client).raiseDispute(TASK_ID);

      const before = await ethers.provider.getBalance(client.address);
      const tx = await contract.connect(owner).resolveDispute(TASK_ID, false);
      const receipt = await tx.wait();
      const gasUsed = 0n; // owner pays gas, not client
      const after = await ethers.provider.getBalance(client.address);

      expect(after - before).to.equal(PRICE); // Full refund, no fee
      expect(await contract.pendingWithdrawals(feeRecipient.address)).to.equal(0);
    });
  });

  // ─── admin ──────────────────────────────────────────────────────────────

  describe('Admin functions', () => {
    it('Owner can update fee recipient', async () => {
      const { contract, owner, other } = await loadFixture(deployFixture);
      await contract.connect(owner).setFeeRecipient(other.address);
      expect(await contract.feeRecipient()).to.equal(other.address);
    });

    it('Owner can update fee basis points', async () => {
      const { contract, owner } = await loadFixture(deployFixture);
      await contract.connect(owner).setFeeBasisPoints(500); // 5%
      expect(await contract.feeBasisPoints()).to.equal(500);
    });

    it('Rejects fee above 10%', async () => {
      const { contract, owner } = await loadFixture(deployFixture);
      await expect(contract.connect(owner).setFeeBasisPoints(1001))
        .to.be.revertedWithCustomError(contract, 'InvalidFee');
    });

    it('Owner can pause and unpause', async () => {
      const { contract, owner, client } = await loadFixture(deployFixture);
      await contract.connect(owner).pause();
      await expect(contract.connect(client).fundTask(TASK_ID, { value: PRICE }))
        .to.be.revertedWithCustomError(contract, 'EnforcedPause');
      await contract.connect(owner).unpause();
      await expect(contract.connect(client).fundTask(TASK_ID, { value: PRICE }))
        .to.not.be.reverted;
    });
  });

  // ─── pull payment ───────────────────────────────────────────────────────

  describe('Pull payment (withdraw)', () => {
    it('Fee recipient can withdraw accumulated fees', async () => {
      const { contract, client, freelancer, feeRecipient } = await loadFixture(deployFixture);
      await workSubmitted(contract, client, freelancer);
      await contract.connect(client).approveWork(TASK_ID);

      const expectedFee = (PRICE * 250n) / 10_000n;
      const before = await ethers.provider.getBalance(feeRecipient.address);
      const tx = await contract.connect(feeRecipient).withdraw();
      const receipt = await tx.wait();
      const gasUsed = receipt!.gasUsed * tx.gasPrice!;
      const after = await ethers.provider.getBalance(feeRecipient.address);

      expect(after).to.be.closeTo(before + expectedFee - gasUsed, ethers.parseEther('0.0001'));
      expect(await contract.pendingWithdrawals(feeRecipient.address)).to.equal(0);
    });

    it('Reverts if nothing to withdraw', async () => {
      const { contract, other } = await loadFixture(deployFixture);
      await expect(contract.connect(other).withdraw())
        .to.be.revertedWithCustomError(contract, 'NothingToWithdraw');
    });
  });
});
