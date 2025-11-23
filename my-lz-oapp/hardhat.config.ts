import 'dotenv/config'
import 'hardhat-deploy'
import '@nomiclabs/hardhat-ethers'
import '@layerzerolabs/toolbox-hardhat'
import { HardhatUserConfig, HttpNetworkAccountsUserConfig } from 'hardhat/types'
import { EndpointId } from '@layerzerolabs/lz-definitions'

const PRIVATE_KEY = process.env.PRIVATE_KEY
const accounts: HttpNetworkAccountsUserConfig | undefined = PRIVATE_KEY ? [PRIVATE_KEY] : undefined

if (accounts == null) {
    console.warn('Could not find PRIVATE_KEY environment variable.')
}

const config: HardhatUserConfig = {
    paths: {
        cache: 'cache/hardhat',
        sources: 'contracts',
    },
    solidity: {
        version: '0.8.22',
        settings: {
            optimizer: {
                enabled: true,
                runs: 1000,
            },
        },
    },
    networks: {
        'sepolia': {
            eid: EndpointId.SEPOLIA_V2_TESTNET,
            url: process.env.ETH_SEPOLIA_RPC || 'https://rpc.sepolia.org',
            accounts,
        },
        'base-sepolia': {
            eid: EndpointId.BASESEP_V2_TESTNET,
            url: process.env.BASE_SEPOLIA_RPC || 'https://sepolia.base.org',
            accounts,
        },
        hardhat: {
            allowUnlimitedContractSize: true,
        },
    },
    namedAccounts: {
        deployer: {
            default: 0,
        },
    },
}

export default config
