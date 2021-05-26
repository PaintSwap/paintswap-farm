const HDWalletProvider = require('truffle-hdwallet-provider');
const path = require("path");

require('dotenv').config();  // Store environment-specific variable from '.env' to process.env


module.exports = {
  // See <http://truffleframework.com/docs/advanced/configuration>
  // to customize your Truffle configuration!
  contracts_build_directory: path.join(__dirname, "build"),
  networks: {
    develop: {
      port: 7545,
      host: "127.0.0.1",
      network_id: 5777
    },
    testnet: {
      provider: () => new HDWalletProvider(process.env.MNEMONIC_TEST, `https://ropsten.infura.io/v3/13114bd1767b441ab638877cafce0890`),
      network_id: 3,
      networkCheckTimeout: 1000000000,
      skipDryRun: true
    },
    ftm_testnet: {
      provider: () => new HDWalletProvider(process.env.MNEMONIC_TEST, "https://rpc.testnet.fantom.network"),
      network_id: 4002,
      gasPrice: 150000000000,
      timeoutBlocks: 200,
      skipDryRun: true
    },
    ftm: {
      provider: () => new HDWalletProvider(process.env.MNEMONIC, "https://rpc.ftm.tools/"),
      network_id: 250,
      gasPrice: 82000000000,
      timeoutBlocks: 200,
      skipDryRun: true
    }
  },	
  compilers: {    
    solc: {
    version: "0.8.4",
      settings: {
        optimizer: {
          enabled: true,
          runs: 200
        }
      }
    }
  }
};
