import assert from 'assert'
import { type DeployFunction } from 'hardhat-deploy/types'

const contractName = 'CctpBridger'

const deploy: DeployFunction = async (hre) => {
    const { getNamedAccounts, deployments } = hre
    const { deploy } = deployments
    const { deployer } = await getNamedAccounts()

    assert(deployer, 'Missing named deployer account')

    console.log(`Network: ${hre.network.name}`)
    console.log(`Deployer: ${deployer}`)

    // Network-specific CCTP addresses
    const cctpConfig: Record<string, { tokenMessenger: string; usdc: string }> = {
        'sepolia': {
            tokenMessenger: '0x9f3B8679c73C2Fef8b59B4f3444d4e156fb70AA5',
            usdc: '0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238',
        },
        'base-sepolia': {
            tokenMessenger: '0x9f3B8679c73C2Fef8b59B4f3444d4e156fb70AA5', // Same on testnets
            usdc: '0x036CbD53842c5426634e7929541eC2318f3dCF7e',
        },
    }

    const config = cctpConfig[hre.network.name]
    if (!config) {
        console.log(`Skipping ${contractName} - not a CCTP source chain`)
        return
    }

    const { address } = await deploy(contractName, {
        from: deployer,
        args: [config.tokenMessenger, config.usdc],
        log: true,
        skipIfAlreadyDeployed: false,
    })

    console.log(`Deployed contract: ${contractName}, network: ${hre.network.name}, address: ${address}`)
}

deploy.tags = [contractName, 'CctpBridger']

export default deploy
