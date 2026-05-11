import { network } from 'hardhat';
import * as dotenv from 'dotenv';

dotenv.config();

async function main() {
  const { ethers } = await network.connect();

  const [deployer] = await ethers.getSigners();

  console.log('Deploying with account:', deployer.address);
  const balance = await deployer.provider!.getBalance(deployer.address);
  console.log('Balance:', ethers.formatEther(balance), 'ETH');

  const feeRecipient = process.env.FEE_RECIPIENT || deployer.address;
  console.log('Fee recipient:', feeRecipient);

  const TaskEscrow = await ethers.getContractFactory('TaskEscrow');
  const contract = await TaskEscrow.deploy(feeRecipient);
  await contract.waitForDeployment();

  const address = await contract.getAddress();
  console.log('✅ TaskEscrow deployed to:', address);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
