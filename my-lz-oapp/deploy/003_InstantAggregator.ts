import assert from 'assert'
import { type DeployFunction } from 'hardhat-deploy/types'

const contractName = 'InstantAggregator'

const deploy: DeployFunction = async (hre) => {
    const { getNamedAccounts, deployments } = hre
    const { deploy } = deployments
    const { deployer } = await getNamedAccounts()

    assert(deployer, 'Missing named deployer account')

    console.log(`Network: ${hre.network.name}`)
    console.log(`Deployer: ${deployer}`)

    // Only deploy on destination chain (Base Sepolia)
    const destinationChains = ['base-sepolia']
    if (!destinationChains.includes(hre.network.name)) {
        console.log(`Skipping ${contractName} - not a destination chain`)
        return
    }

    const endpointV2Deployment = await hre.deployments.get('EndpointV2')
    const messageTransmitter = '0x7865fAfC2db2093669d92c0F33AeEF291086BEFD' // Base Sepolia

    const { address } = await deploy(contractName, {
        from: deployer,
        args: [
            endpointV2Deployment.address,
            messageTransmitter,
            deployer, // owner
        ],
        log: true,
        skipIfAlreadyDeployed: false,
    })

    console.log(`Deployed contract: ${contractName}, network: ${hre.network.name}, address: ${address}`)

    // Configure swap router and USDC after deployment
    const deployment = await deployments.get(contractName)
    const instantAggregator = await hre.ethers.getContractAt(contractName, deployment.address)

    const swapRouter = '0x94cC0AaC535CCDB3C01d6787D6413C739ae12bc4' // Base Sepolia Uniswap
    const usdc = '0x036CbD53842c5426634e7929541eC2318f3dCF7e' // Base Sepolia USDC

    console.log(`Configuring ${contractName}...`)
    const tx = await instantAggregator.setSwapConfig(swapRouter, usdc)
    await tx.wait()
    console.log(`✅ ${contractName} configured with swap router and USDC`)
}

deploy.tags = [contractName, 'InstantAggregator']

export default deploy
