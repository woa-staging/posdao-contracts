pragma solidity 0.5.10;

import "./StakingAuRaBase.sol";
import "../interfaces/IBlockRewardAuRaTokens.sol";
import "../interfaces/IStakingAuRaTokens.sol";


/// @dev Implements staking and withdrawal logic.
contract StakingAuRaTokens is IStakingAuRaTokens, StakingAuRaBase {

    // =============================================== Storage ========================================================

    // WARNING: since this contract is upgradeable, do not remove
    // existing storage variables, do not change their order,
    // and do not change their types!

    /// @dev The address of the ERC677 staking token contract.
    IERC677 public erc677TokenContract;

    // =============================================== Structs ========================================================

    /// @dev Used by the `claimReward` function to reduce stack depth.
    struct RewardAmounts {
        uint256 tokenAmount;
        uint256 nativeAmount;
    }

    // ================================================ Events ========================================================

    /// @dev Emitted by the `claimReward` function to signal the staker withdrew the specified
    /// amount of tokens and native coins from the specified pool for the specified staking epoch.
    /// @param fromPoolStakingAddress The pool from which the `staker` withdrew the amounts.
    /// @param staker The address of the staker that withdrew the amounts.
    /// @param stakingEpoch The serial number of the staking epoch for which the claim was made.
    /// @param tokensAmount The withdrawal amount of tokens.
    /// @param nativeCoinsAmount The withdrawal amount of native coins.
    event ClaimedReward(
        address indexed fromPoolStakingAddress,
        address indexed staker,
        uint256 indexed stakingEpoch,
        uint256 tokensAmount,
        uint256 nativeCoinsAmount
    );

    // =============================================== Setters ========================================================

    /// @dev Withdraws a reward from the specified pool for the specified staking epochs
    /// to the staker address (msg.sender).
    /// @param _stakingEpochs The list of staking epochs in ascending order.
    /// If the list is empty, it is taken with `BlockRewardAuRa.epochsPoolGotRewardFor` getter.
    /// @param _poolStakingAddress The staking address of the pool from which the reward needs to be withdrawn.
    function claimReward(
        uint256[] memory _stakingEpochs,
        address _poolStakingAddress
    ) public gasPriceIsValid onlyInitialized {
        address payable staker = msg.sender;
        uint256 firstEpoch;
        uint256 lastEpoch;

        if (_poolStakingAddress != staker) { // this is a delegator
            firstEpoch = stakeFirstEpoch[_poolStakingAddress][staker];
            require(firstEpoch != 0);
            lastEpoch = stakeLastEpoch[_poolStakingAddress][staker];
        }

        IBlockRewardAuRaTokens blockRewardContract = IBlockRewardAuRaTokens(validatorSetContract.blockRewardContract());
        address miningAddress = validatorSetContract.miningByStakingAddress(_poolStakingAddress);
        RewardAmounts memory rewardSum = RewardAmounts(0, 0);
        uint256 delegatorStake = 0;

        if (_stakingEpochs.length == 0) {
            _stakingEpochs = IBlockRewardAuRa(address(blockRewardContract)).epochsPoolGotRewardFor(miningAddress);
        }

        for (uint256 i = 0; i < _stakingEpochs.length; i++) {
            uint256 epoch = _stakingEpochs[i];

            require(i == 0 || epoch > _stakingEpochs[i - 1]);
            require(epoch < stakingEpoch);

            if (rewardWasTaken[_poolStakingAddress][staker][epoch]) continue;
            
            RewardAmounts memory reward;

            if (_poolStakingAddress != staker) { // this is a delegator
                if (epoch < firstEpoch) {
                    // If the delegator staked for the first time before
                    // the `epoch`, skip this staking epoch
                    continue;
                }

                if (lastEpoch <= epoch && lastEpoch != 0) {
                    // If the delegator withdrew all their stake before the `epoch`,
                    // don't check this and following epochs since it makes no sense
                    break;
                }

                delegatorStake = _getDelegatorStake(epoch, firstEpoch, delegatorStake, _poolStakingAddress, staker);
                firstEpoch = epoch + 1;

                (reward.tokenAmount, reward.nativeAmount) =
                    blockRewardContract.getDelegatorReward(delegatorStake, epoch, miningAddress);
            } else { // this is a validator
                (reward.tokenAmount, reward.nativeAmount) =
                    blockRewardContract.getValidatorReward(epoch, miningAddress);
            }

            rewardSum.tokenAmount = rewardSum.tokenAmount.add(reward.tokenAmount);
            rewardSum.nativeAmount = rewardSum.nativeAmount.add(reward.nativeAmount);

            rewardWasTaken[_poolStakingAddress][staker][epoch] = true;

            emit ClaimedReward(_poolStakingAddress, staker, epoch, reward.tokenAmount, reward.nativeAmount);
        }

        blockRewardContract.transferReward(rewardSum.tokenAmount, rewardSum.nativeAmount, staker);
    }

    /// @dev Stakes the sent tokens to the specified pool by the specified staker.
    /// Fails if called not by `ERC677BridgeTokenRewardable.transferAndCall` function.
    /// This function allows to use the `transferAndCall` function of the token contract
    /// instead of the `stake` function. It can be useful if the token contract doesn't
    /// contain a separate `stake` function.
    /// @param _staker The address that sent the tokens. Must be a pool's staking address or delegator's address.
    /// @param _amount The amount of tokens transferred to this contract.
    /// @param _data A data field encoding the staker's address or miningAddress (in case of adding a new pool).
    /// The first 20 bytes must represent the staker's address.
    /// The last optional byte is a boolean flag indicating whether the first 20 bytes
    /// represent the staker's address or miningAddress. If the flag is zero (by default),
    /// this function calls the internal `_stake` function to stake the received tokens
    /// to the specified staking pool (staking address). If the flag is not zero,
    /// this function calls the internal `_addPool` function to add a new candidate's pool
    /// to the list of active pools. In this case, the first 20 bytes of the `_data` field
    /// represent the mining address which should be bound to the staking address defined
    /// by the `_staker` param.
    function onTokenTransfer(
        address _staker,
        uint256 _amount,
        bytes memory _data
    ) public onlyInitialized returns(bool) {
        require(msg.sender == address(erc677TokenContract));
        require(_data.length == 20 || _data.length == 21);
        address inputAddress;
        bool isAddPool;
        assembly {
            let dataLengthless := mload(add(_data, 32))
            inputAddress := shr(96, dataLengthless)
            isAddPool := gt(and(shr(88, dataLengthless), 0xff), 0)
        }
        if (isAddPool) {
            _addPool(_amount, _staker, inputAddress, true);
        } else {
            _stake(inputAddress, _staker, _amount);
        }
        return true;
    }

    /// @dev Sets the address of the ERC677 staking token contract. Can only be called by the `owner`.
    /// Cannot be called if there was at least one stake in staking tokens before.
    /// @param _erc677TokenContract The address of the contract.
    function setErc677TokenContract(IERC677 _erc677TokenContract) external onlyOwner onlyInitialized {
        require(_erc677TokenContract != IERC677(0));
        require(erc677TokenContract == IERC677(0));
        erc677TokenContract = _erc677TokenContract;
        require(_thisBalance() == 0);
    }

    // =============================================== Getters ========================================================

    /// @dev Returns reward amounts for the specified pool, the specified staking epochs,
    /// and the specified staker address (delegator or validator).
    /// @param _stakingEpochs The list of staking epochs in ascending order.
    /// If the list is empty, it is taken with `BlockRewardAuRa.epochsPoolGotRewardFor` getter.
    /// @param _poolStakingAddress The staking address of the pool for which the amounts need to be returned.
    /// @param _staker The staker address (validator's staking address or delegator's address).
    function getRewardAmount(
        uint256[] memory _stakingEpochs,
        address _poolStakingAddress,
        address _staker
    ) public view returns(uint256 tokenRewardSum, uint256 nativeRewardSum) {
        uint256 firstEpoch;
        uint256 lastEpoch;

        if (_poolStakingAddress != _staker) { // this is a delegator
            firstEpoch = stakeFirstEpoch[_poolStakingAddress][_staker];
            require(firstEpoch != 0);
            lastEpoch = stakeLastEpoch[_poolStakingAddress][_staker];
        }

        IBlockRewardAuRaTokens blockRewardContract = IBlockRewardAuRaTokens(validatorSetContract.blockRewardContract());
        address miningAddress = validatorSetContract.miningByStakingAddress(_poolStakingAddress);
        uint256 delegatorStake = 0;
        tokenRewardSum = 0;
        nativeRewardSum = 0;

        if (_stakingEpochs.length == 0) {
            _stakingEpochs = IBlockRewardAuRa(address(blockRewardContract)).epochsPoolGotRewardFor(miningAddress);
        }

        for (uint256 i = 0; i < _stakingEpochs.length; i++) {
            uint256 epoch = _stakingEpochs[i];

            require(i == 0 || epoch > _stakingEpochs[i - 1]);
            require(epoch < stakingEpoch);

            if (rewardWasTaken[_poolStakingAddress][_staker][epoch]) continue;

            if (_poolStakingAddress != _staker) { // this is a delegator
                if (epoch < firstEpoch) continue;
                if (lastEpoch <= epoch && lastEpoch != 0) break;

                delegatorStake = _getDelegatorStake(epoch, firstEpoch, delegatorStake, _poolStakingAddress, _staker);
                firstEpoch = epoch + 1;

                (uint256 tokenAmount, uint256 nativeAmount) =
                    blockRewardContract.getDelegatorReward(delegatorStake, epoch, miningAddress);
                tokenRewardSum += tokenAmount;
                nativeRewardSum += nativeAmount;
            } else { // this is a validator
                (uint256 tokenAmount, uint256 nativeAmount) =
                    blockRewardContract.getValidatorReward(epoch, miningAddress);
                tokenRewardSum += tokenAmount;
                nativeRewardSum += nativeAmount;
            }
        }
    }

    // ============================================== Internal ========================================================

    /// @dev Sends tokens from this contract to the specified address.
    /// @param _to The target address to send amount to.
    /// @param _amount The amount to send.
    function _sendWithdrawnStakeAmount(address payable _to, uint256 _amount) internal gasPriceIsValid onlyInitialized {
        require(erc677TokenContract != IERC677(0));
        erc677TokenContract.transfer(_to, _amount);
        lastChangeBlock = _getCurrentBlockNumber();
    }

    /// @dev The internal function used by the `stake` and `addPool` functions.
    /// See the `stake` public function for more details.
    /// @param _toPoolStakingAddress The staking address of the pool where the tokens should be staked.
    /// @param _amount The amount of tokens to be staked.
    function _stake(address _toPoolStakingAddress, uint256 _amount) internal {
        address staker = msg.sender;
        _stake(_toPoolStakingAddress, staker, _amount);
        require(msg.value == 0);
        require(erc677TokenContract != IERC677(0));
        erc677TokenContract.stake(staker, _amount);
    }

    /// @dev Returns the balance of this contract in staking tokens.
    function _thisBalance() internal view returns(uint256) {
        return erc677TokenContract.balanceOf(address(this));
    }
}
