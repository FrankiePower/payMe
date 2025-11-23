import assert from 'assert'
import { type DeployFunction } from 'hardhat-deploy/types'

const contractName = 'SourceChainInitiator'

const deploy: DeployFunction = async (hre) => {
    const { getNamedAccounts, deployments } = hre
    const { deploy } = deployments
    const { deployer } = await getNamedAccounts()

    assert(deployer, 'Missing named deployer account')

    console.log(`Network: ${hre.network.name}`)
    console.log(`Deployer: ${deployer}`)

    // Only deploy on source chains (ETH Sepolia)
    const sourceChains = ['sepolia']
    if (!sourceChains.includes(hre.network.name)) {
        console.log(`Skipping ${contractName} - not a source chain`)
        return
    }

    const endpointV2Deployment = await hre.deployments.get('EndpointV2')
    const cctpBridgerDeployment = await hre.deployments.get('CctpBridger')

    const usdc = '0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238' // ETH Sepolia USDC

    const { address } = await deploy(contractName, {
        from: deployer,
        args: [
            endpointV2Deployment.address,
            usdc,
            cctpBridgerDeployment.address,
            deployer, // owner
        ],
        log: true,
        skipIfAlreadyDeployed: false,
    })

    console.log(`Deployed contract: ${contractName}, network: ${hre.network.name}, address: ${address}`)
}

deploy.tags = [contractName, 'SourceChainInitiator']
deploy.dependencies = ['CctpBridger']

export default deploy
