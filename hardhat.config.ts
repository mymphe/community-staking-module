import fs from "fs";
import "hardhat-preprocessor";
import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import { anvilStop, anvilStart } from "./test/anvil-fixtures";

function getRemappings() {
  return fs
    .readFileSync("remappings.txt", "utf8")
    .split("\n")
    .filter(Boolean)
    .map((line) => line.trim().split("="));
}

const config: HardhatUserConfig = {
  solidity: {
    version: "0.8.21",
    settings: {
      optimizer: {
        enabled: true,
        runs: 1_000,
      },
    },
  },
  defaultNetwork: "anvil",
  networks: {
    hardhat: {
      loggingEnabled: true,
    },
    anvil: {
      url: "http://127.0.0.1:7545",
      forking: {
        url: process.env.RPC_URL ?? "",
      },
      loggingEnabled: true,
    },
  },
  mocha: {
    rootHooks: {
      beforeAll: async () => {
        await anvilStart();
      },
      afterAll: async () => {
        await anvilStop();
      },
    },
  },
  paths: {
    sources: "./src", // Use ./src rather than ./contracts as Hardhat expects
    cache: "./cache_hardhat", // Use a different cache for Hardhat than Foundry
  },
  // This fully resolves paths for imports in the ./lib directory for Hardhat
  preprocess: {
    eachLine: (hre) => ({
      transform: (line: string) => {
        if (line.match(/^\s*import /i)) {
          getRemappings().forEach(([find, replace]) => {
            if (line.match(find)) {
              line = line.replace(find, replace);
            }
          });
        }
        return line;
      },
    }),
  },
};

export default config;
