import { network } from 'hardhat';
import * as dotenv from 'dotenv';
import * as fs from 'fs';
import * as path from 'path';

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
  console.log('');
  console.log('Add to your .env.local:');
  console.log(`NEXT_PUBLIC_CONTRACT_ADDRESS=${address}`);

  // Optionally write to a deployment file for reference
  const deploymentInfo = {
    address,
    deployer: deployer.address,
    feeRecipient,
    deployedAt: new Date().toISOString(),
  };

  const deploymentPath = path.resolve('./deployments.json');
  fs.writeFileSync(deploymentPath, JSON.stringify(deploymentInfo, null, 2));
  console.log('Deployment info saved to deployments.json');
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
