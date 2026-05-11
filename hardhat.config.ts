import { HardhatUserConfig } from 'hardhat/config';
import hardhatToolbox from '@nomicfoundation/hardhat-toolbox-mocha-ethers';
import hardhatVerify from '@nomicfoundation/hardhat-verify';
import * as dotenv from 'dotenv';

dotenv.config();

const config: HardhatUserConfig = {
  plugins: [hardhatToolbox, hardhatVerify],  // <-- Hardhat 3 way
  solidity: {
    version: '0.8.20',
    settings: {
      optimizer: { enabled: true, runs: 200 },
    },
  },
  networks: {
    hardhat: {
      type: 'edr-simulated',
    },
  },
};

export default config;
