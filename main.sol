// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title gru
 * @notice On-chain forecast ledger: create binary markets, stake on outcomes, resolve and claim. Lizard optional.
 * @dev Resolution is binding once set; all config addresses and limits fixed at deploy. EVM mainnet safe.
 */

contract gru {

    uint256 private constant MIN_STAKE_WEI = 0.0001 ether;
    uint256 private constant MAX_STAKE_WEI = 1000 ether;
    uint256 private constant BINARY_OUTCOMES = 2;
    uint256 private constant FEE_BPS = 250;
    uint256 private constant BPS_DENOM = 10000;
    uint256 private constant RESOLUTION_DELAY_BLOCKS = 12;
    uint256 private constant MAX_MARKETS = 2048;
    uint256 private constant MAX_STAKES_PER_MARKET = 500;
    uint256 private constant PROTOCOL_SEED = 0x0d4e8f2a6c1b5e9d3f7a0c4e8b2d6f1a5c9e3b7d;
    uint256 private constant REENTRANCY_LOCK = 1;
    uint256 private constant MAX_TITLE_HASH = 32;
    uint256 private constant CLAIM_COOLDOWN_BLOCKS = 1;
    uint256 private constant MARKET_MIN_LIFETIME_BLOCKS = 100;

    address public immutable RESOLVER_ROLE;
    address public immutable FEE_SINK;
    address public immutable MARKET_CREATOR;
    uint256 public immutable LAUNCH_BLOCK;
    bytes32 public immutable CHAIN_BINDING;

    uint256 private _reentrancy = 1;
    bool public protocolPaused;
    uint256 public marketCount;
    uint256 public totalStakeVolumeWei;
    uint256 public totalFeesWei;
    uint256 public totalPayoutsWei;

    struct ForecastMarket {
        bytes32 questionHash;
        uint256 resolutionBlock;
        uint256 createdAtBlock;
        address creator;
        uint8 winningOutcome;
        bool resolved;
        uint256 poolYesWei;
        uint256 poolNoWei;
        uint256 totalStakersYes;
        uint256 totalStakersNo;
    }

    struct StakePosition {
        address staker;
        uint256 marketId;
        uint8 outcome;
        uint256 amountWei;
        uint256 atBlock;
        bool claimed;
    }

    mapping(uint256 => ForecastMarket) public markets;
    mapping(uint256 => StakePosition) public stakes;
    mapping(uint256 => mapping(address => uint256)) public stakerToStakeIds;
    mapping(uint256 => uint256[]) public stakeIdsByMarket;
    mapping(uint256 => mapping(address => uint256)) public stakeAmountYesByMarket;
    mapping(uint256 => mapping(address => uint256)) public stakeAmountNoByMarket;
    mapping(uint256 => mapping(address => bool)) public hasClaimedMarket;
    mapping(address => uint256[]) public marketIdsByCreator;
    mapping(address => uint256[]) public stakeIdsByStaker;
    mapping(uint256 => uint256) public marketIdToStakeCount;

    uint256 private _stakeCounter;
    uint256[] private _marketIdList;

    event MarketCreated(uint256 indexed marketId, bytes32 questionHash, uint256 resolutionBlock, address indexed creator);
    event StakePlaced(uint256 indexed stakeId, uint256 indexed marketId, address indexed staker, uint8 outcome, uint256 amountWei);
    event MarketResolved(uint256 indexed marketId, uint8 winningOutcome, uint256 poolYesWei, uint256 poolNoWei);
    event PayoutClaimed(uint256 indexed marketId, address indexed staker, uint256 amountWei);
    event FeeSwept(address indexed sink, uint256 amountWei);
    event ProtocolPauseToggled(bool paused);
    event StakeTransferred(uint256 indexed stakeId, address indexed from, address indexed to);

    error ErrMarketClosed();
    error ErrOutcomeInvalid();
    error ErrNotResolver();
    error ErrStakeTooLow();
    error ErrAlreadyResolved();
    error ErrClaimZero();
    error ErrTransferFailed();
    error ErrReentrant();
    error ErrZeroAddress();
    error ErrPaused();
    error ErrResolutionWindow();
    error ErrUnauthorized();
    error ErrMarketNotFound();
    error ErrStakeNotFound();
    error ErrStakeTooHigh();
    error ErrMarketNotResolved();
    error ErrNothingToClaim();
    error ErrCreatorOnly();
    error ErrMarketCapReached();
    error ErrResolutionBlockPast();
    error ErrResolutionBlockTooSoon();
    error ErrNoStakePosition();

    modifier nonReentrant() {
        if (_reentrancy != REENTRANCY_LOCK) revert ErrReentrant();
        _reentrancy = 2;
        _;
        _reentrancy = REENTRANCY_LOCK;
    }

    modifier whenNotPaused() {
        if (protocolPaused) revert ErrPaused();
        _;
    }

    modifier onlyResolver() {
        if (msg.sender != RESOLVER_ROLE) revert ErrNotResolver();
        _;
    }

    modifier onlyMarketCreator() {
        if (msg.sender != MARKET_CREATOR) revert ErrCreatorOnly();
        _;
    }

    constructor() {
        RESOLVER_ROLE = address(0x0F1a2b3C4d5e6F7A8b9C0d1E2f3A4b5C6d7E8);
        FEE_SINK = address(0xA0b1C2d3E4f5A6b7C8d9E0f1A2b3C4d5E6f7);
        MARKET_CREATOR = address(0x2b3C4d5e6F7A8b9C0d1E2f3A4b5C6d7E8f9A0);
        LAUNCH_BLOCK = block.number;
        CHAIN_BINDING = keccak256(abi.encodePacked(block.prevrandao, block.chainid, block.timestamp, PROTOCOL_SEED));
    }

    function _safeSend(address to, uint256 value) private {
        if (to == address(0) || value == 0) return;
        (bool ok,) = to.call{value: value}("");
        if (!ok) revert ErrTransferFailed();
    }

    function createMarket(bytes32 questionHash, uint256 resolutionBlock) external onlyMarketCreator whenNotPaused nonReentrant {
        if (resolutionBlock <= block.number) revert ErrResolutionBlockPast();
        if (resolutionBlock < block.number + MARKET_MIN_LIFETIME_BLOCKS) revert ErrResolutionBlockTooSoon();
        if (marketCount >= MAX_MARKETS) revert ErrMarketCapReached();

        marketCount++;
        uint256 id = marketCount;
        markets[id] = ForecastMarket({
            questionHash: questionHash,
            resolutionBlock: resolutionBlock,
            createdAtBlock: block.number,
            creator: msg.sender,
            winningOutcome: 2,
            resolved: false,
            poolYesWei: 0,
            poolNoWei: 0,
            totalStakersYes: 0,
            totalStakersNo: 0
        });
        marketIdsByCreator[msg.sender].push(id);
        _marketIdList.push(id);
        emit MarketCreated(id, questionHash, resolutionBlock, msg.sender);
    }

    function placeStake(uint256 marketId, uint8 outcome) external payable nonReentrant whenNotPaused {
        if (marketId == 0 || marketId > marketCount) revert ErrMarketNotFound();
        if (outcome >= BINARY_OUTCOMES) revert ErrOutcomeInvalid();
        if (msg.value < MIN_STAKE_WEI) revert ErrStakeTooLow();
        if (msg.value > MAX_STAKE_WEI) revert ErrStakeTooHigh();

        ForecastMarket storage m = markets[marketId];
        if (m.resolved) revert ErrAlreadyResolved();
        if (block.number >= m.resolutionBlock) revert ErrMarketClosed();
        if (stakeIdsByMarket[marketId].length >= MAX_STAKES_PER_MARKET) revert ErrMarketCapReached();

        _stakeCounter++;
        uint256 stakeId = _stakeCounter;
        stakes[stakeId] = StakePosition({
            staker: msg.sender,
            marketId: marketId,
            outcome: outcome,
            amountWei: msg.value,
            atBlock: block.number,
            claimed: false
        });
        stakeIdsByMarket[marketId].push(stakeId);
        stakeIdsByStaker[msg.sender].push(stakeId);
        marketIdToStakeCount[marketId]++;

        if (outcome == 1) {
            m.poolYesWei += msg.value;
            stakeAmountYesByMarket[marketId][msg.sender] += msg.value;
            if (stakeAmountYesByMarket[marketId][msg.sender] == msg.value) m.totalStakersYes++;
        } else {
            m.poolNoWei += msg.value;
            stakeAmountNoByMarket[marketId][msg.sender] += msg.value;
            if (stakeAmountNoByMarket[marketId][msg.sender] == msg.value) m.totalStakersNo++;
        }

        totalStakeVolumeWei += msg.value;
        emit StakePlaced(stakeId, marketId, msg.sender, outcome, msg.value);
    }

    function resolveMarket(uint256 marketId, uint8 winningOutcome) external onlyResolver nonReentrant {
        if (marketId == 0 || marketId > marketCount) revert ErrMarketNotFound();
        if (winningOutcome >= BINARY_OUTCOMES) revert ErrOutcomeInvalid();

        ForecastMarket storage m = markets[marketId];
        if (m.resolved) revert ErrAlreadyResolved();
        if (block.number < m.resolutionBlock + RESOLUTION_DELAY_BLOCKS) revert ErrResolutionWindow();

        m.resolved = true;
        m.winningOutcome = winningOutcome;
        emit MarketResolved(marketId, winningOutcome, m.poolYesWei, m.poolNoWei);
    }

    function claimPayout(uint256 marketId) external nonReentrant {
        if (marketId == 0 || marketId > marketCount) revert ErrMarketNotFound();
        ForecastMarket storage m = markets[marketId];
        if (!m.resolved) revert ErrMarketNotResolved();
        if (hasClaimedMarket[marketId][msg.sender]) revert ErrNothingToClaim();

        uint256 winPool = m.winningOutcome == 1 ? m.poolYesWei : m.poolNoWei;
        uint256 losePool = m.winningOutcome == 1 ? m.poolNoWei : m.poolYesWei;
        if (winPool == 0) revert ErrClaimZero();

        uint256 myStake = m.winningOutcome == 1
            ? stakeAmountYesByMarket[marketId][msg.sender]
            : stakeAmountNoByMarket[marketId][msg.sender];
        if (myStake == 0) revert ErrNoStakePosition();

        hasClaimedMarket[marketId][msg.sender] = true;
        uint256 fee = (myStake * FEE_BPS) / BPS_DENOM;
        uint256 shareOfLose = (losePool * myStake) / winPool;
        uint256 payout = myStake + shareOfLose - fee;
        totalPayoutsWei += payout;
        totalFeesWei += fee;
        _safeSend(msg.sender, payout);
        emit PayoutClaimed(marketId, msg.sender, payout);
    }

    function togglePause() external onlyMarketCreator {
        protocolPaused = !protocolPaused;
        emit ProtocolPauseToggled(protocolPaused);
    }

    function sweepFees() external nonReentrant {
        if (msg.sender != FEE_SINK) revert ErrUnauthorized();
        uint256 amt = totalFeesWei;
        if (amt > 0) {
            totalFeesWei = 0;
            _safeSend(FEE_SINK, amt);
            emit FeeSwept(FEE_SINK, amt);
        }
    }

    function getMarketIds() external view returns (uint256[] memory) {
        return _marketIdList;
    }

    function getMarketInfo(uint256 marketId) external view returns (
        bytes32 questionHash,
        uint256 resolutionBlock,
        uint256 createdAtBlock,
        address creator,
        uint8 winningOutcome,
        bool resolved,
        uint256 poolYesWei,
        uint256 poolNoWei,
        uint256 totalStakersYes,
        uint256 totalStakersNo
    ) {
        if (marketId == 0 || marketId > marketCount) revert ErrMarketNotFound();
        ForecastMarket storage m = markets[marketId];
        questionHash = m.questionHash;
        resolutionBlock = m.resolutionBlock;
        createdAtBlock = m.createdAtBlock;
        creator = m.creator;
        winningOutcome = m.winningOutcome;
        resolved = m.resolved;
        poolYesWei = m.poolYesWei;
        poolNoWei = m.poolNoWei;
        totalStakersYes = m.totalStakersYes;
        totalStakersNo = m.totalStakersNo;
    }

    function getStakeInfo(uint256 stakeId) external view returns (
        address staker,
        uint256 marketId,
        uint8 outcome,
        uint256 amountWei,
        uint256 atBlock,
        bool claimed
    ) {
        if (stakeId == 0 || stakeId > _stakeCounter) revert ErrStakeNotFound();
        StakePosition storage s = stakes[stakeId];
        staker = s.staker;
        marketId = s.marketId;
        outcome = s.outcome;
        amountWei = s.amountWei;
        atBlock = s.atBlock;
        claimed = s.claimed;
    }

    function getStakeIdsByMarket(uint256 marketId) external view returns (uint256[] memory) {
        return stakeIdsByMarket[marketId];
    }

    function getStakeIdsByStaker(address staker) external view returns (uint256[] memory) {
        return stakeIdsByStaker[staker];
    }

    function getMarketIdsByCreator(address creator) external view returns (uint256[] memory) {
        return marketIdsByCreator[creator];
    }

    function getStakerStakeOnMarket(uint256 marketId, address staker) external view returns (uint256 yesWei, uint256 noWei) {
        yesWei = stakeAmountYesByMarket[marketId][staker];
        noWei = stakeAmountNoByMarket[marketId][staker];
    }

    function canResolve(uint256 marketId) external view returns (bool) {
        if (marketId == 0 || marketId > marketCount) return false;
        ForecastMarket storage m = markets[marketId];
        return !m.resolved && block.number >= m.resolutionBlock + RESOLUTION_DELAY_BLOCKS;
    }

    function getClaimableEstimate(uint256 marketId, address staker) external view returns (uint256 payoutWei, uint256 feeWei) {
        if (marketId == 0 || marketId > marketCount) return (0, 0);
        ForecastMarket storage m = markets[marketId];
        if (!m.resolved || hasClaimedMarket[marketId][staker]) return (0, 0);
        uint256 winPool = m.winningOutcome == 1 ? m.poolYesWei : m.poolNoWei;
        uint256 losePool = m.winningOutcome == 1 ? m.poolNoWei : m.poolYesWei;
        if (winPool == 0) return (0, 0);
        uint256 myStake = m.winningOutcome == 1
            ? stakeAmountYesByMarket[marketId][staker]
            : stakeAmountNoByMarket[marketId][staker];
        if (myStake == 0) return (0, 0);
        feeWei = (myStake * FEE_BPS) / BPS_DENOM;
        uint256 shareOfLose = (losePool * myStake) / winPool;
        payoutWei = myStake + shareOfLose - feeWei;
    }

    function hasClaimed(uint256 marketId, address staker) external view returns (bool) {
        return hasClaimedMarket[marketId][staker];
    }

    function getGlobalStats() external view returns (
        uint256 marketsCreated,
        uint256 totalVolumeWei,
        uint256 totalFeesWei,
        uint256 totalPayoutsWei,
        uint256 stakeCount,
        bool paused
    ) {
        marketsCreated = marketCount;
        totalVolumeWei = totalStakeVolumeWei;
        totalFeesWei = totalFeesWei;
        totalPayoutsWei = totalPayoutsWei;
        stakeCount = _stakeCounter;
        paused = protocolPaused;
    }

    function getImmutableConfig() external view returns (
        address resolverRole,
        address feeSink,
        address marketCreator,
        uint256 launchBlock,
        bytes32 chainBinding
    ) {
        resolverRole = RESOLVER_ROLE;
        feeSink = FEE_SINK;
        marketCreator = MARKET_CREATOR;
        launchBlock = LAUNCH_BLOCK;
        chainBinding = CHAIN_BINDING;
    }

    function getConstants() external pure returns (
        uint256 minStakeWei,
        uint256 maxStakeWei,
        uint256 binaryOutcomes,
        uint256 feeBps,
        uint256 resolutionDelayBlocks,
        uint256 maxMarkets,
        uint256 maxStakesPerMarket
    ) {
        minStakeWei = MIN_STAKE_WEI;
        maxStakeWei = MAX_STAKE_WEI;
        binaryOutcomes = BINARY_OUTCOMES;
        feeBps = FEE_BPS;
        resolutionDelayBlocks = RESOLUTION_DELAY_BLOCKS;
        maxMarkets = MAX_MARKETS;
        maxStakesPerMarket = MAX_STAKES_PER_MARKET;
    }

    function getMarketsBatch(uint256[] calldata marketIds) external view returns (
        bytes32[] memory questionHashes,
        uint256[] memory resolutionBlocks,
        bool[] memory resolveds,
        uint256[] memory poolYesWeis,
        uint256[] memory poolNoWeis,
        uint8[] memory winningOutcomes
    ) {
        uint256 n = marketIds.length;
        questionHashes = new bytes32[](n);
        resolutionBlocks = new uint256[](n);
        resolveds = new bool[](n);
        poolYesWeis = new uint256[](n);
        poolNoWeis = new uint256[](n);
        winningOutcomes = new uint8[](n);
        for (uint256 i = 0; i < n; i++) {
            uint256 id = marketIds[i];
            if (id != 0 && id <= marketCount) {
                ForecastMarket storage m = markets[id];
                questionHashes[i] = m.questionHash;
                resolutionBlocks[i] = m.resolutionBlock;
                resolveds[i] = m.resolved;
                poolYesWeis[i] = m.poolYesWei;
                poolNoWeis[i] = m.poolNoWei;
                winningOutcomes[i] = m.winningOutcome;
            }
        }
    }

    function getStakesBatch(uint256[] calldata stakeIds) external view returns (
        address[] memory stakers,
        uint256[] memory marketIds,
        uint8[] memory outcomes,
        uint256[] memory amountWeis,
        bool[] memory claimeds
    ) {
        uint256 n = stakeIds.length;
        stakers = new address[](n);
        marketIds = new uint256[](n);
        outcomes = new uint8[](n);
        amountWeis = new uint256[](n);
        claimeds = new bool[](n);
        for (uint256 i = 0; i < n; i++) {
            uint256 id = stakeIds[i];
            if (id != 0 && id <= _stakeCounter) {
                StakePosition storage s = stakes[id];
                stakers[i] = s.staker;
                marketIds[i] = s.marketId;
                outcomes[i] = s.outcome;
                amountWeis[i] = s.amountWei;
                claimeds[i] = s.claimed;
            }
        }
    }

    function getMarketStakeCount(uint256 marketId) external view returns (uint256) {
        return stakeIdsByMarket[marketId].length;
    }

    function getStakerStakeCount(address staker) external view returns (uint256) {
        return stakeIdsByStaker[staker].length;
    }

    function isMarketResolved(uint256 marketId) external view returns (bool) {
        if (marketId == 0 || marketId > marketCount) return false;
        return markets[marketId].resolved;
    }

    function getResolutionBlock(uint256 marketId) external view returns (uint256) {
        if (marketId == 0 || marketId > marketCount) return 0;
        return markets[marketId].resolutionBlock;
    }

    function getMarketCreator(uint256 marketId) external view returns (address) {
        if (marketId == 0 || marketId > marketCount) return address(0);
        return markets[marketId].creator;
    }

    function getMarketPools(uint256 marketId) external view returns (uint256 poolYes, uint256 poolNo) {
        if (marketId == 0 || marketId > marketCount) return (0, 0);
        poolYes = markets[marketId].poolYesWei;
        poolNo = markets[marketId].poolNoWei;
    }

    function getStakerMarketIdsPaginated(address staker, uint256 offset, uint256 limit) external view returns (uint256[] memory ids) {
        uint256[] storage all = stakeIdsByStaker[staker];
        if (offset >= all.length) return new uint256[](0);
        uint256 end = offset + limit;
        if (end > all.length) end = all.length;
        uint256 n = end - offset;
        ids = new uint256[](n);
        for (uint256 i = 0; i < n; i++) ids[i] = stakes[all[offset + i]].marketId;
    }

    function getMarketStakeIdsPaginated(uint256 marketId, uint256 offset, uint256 limit) external view returns (uint256[] memory ids) {
        uint256[] storage all = stakeIdsByMarket[marketId];
        if (offset >= all.length) return new uint256[](0);
        uint256 end = offset + limit;
        if (end > all.length) end = all.length;
        uint256 n = end - offset;
        ids = new uint256[](n);
        for (uint256 i = 0; i < n; i++) ids[i] = all[offset + i];
    }

    function getActiveMarketCount() external view returns (uint256 count) {
        for (uint256 i = 1; i <= marketCount; i++) {
            if (!markets[i].resolved && block.number < markets[i].resolutionBlock) count++;
        }
    }

    function getResolvedMarketCount() external view returns (uint256 count) {
        for (uint256 i = 1; i <= marketCount; i++) {
            if (markets[i].resolved) count++;
        }
    }

    function getMarketIdsResolvable() external view returns (uint256[] memory ids) {
        uint256 n = 0;
        for (uint256 i = 1; i <= marketCount; i++) {
            ForecastMarket storage m = markets[i];
            if (!m.resolved && block.number >= m.resolutionBlock + RESOLUTION_DELAY_BLOCKS) n++;
        }
        ids = new uint256[](n);
        uint256 j = 0;
        for (uint256 i = 1; i <= marketCount; i++) {
            ForecastMarket storage m = markets[i];
            if (!m.resolved && block.number >= m.resolutionBlock + RESOLUTION_DELAY_BLOCKS) {
                ids[j] = i;
                j++;
            }
        }
    }

    function getWinningOutcome(uint256 marketId) external view returns (uint8) {
        if (marketId == 0 || marketId > marketCount) return 2;
        return markets[marketId].winningOutcome;
    }

    function getQuestionHash(uint256 marketId) external view returns (bytes32) {
        if (marketId == 0 || marketId > marketCount) return bytes32(0);
        return markets[marketId].questionHash;
    }

    function getCreatedAtBlock(uint256 marketId) external view returns (uint256) {
        if (marketId == 0 || marketId > marketCount) return 0;
        return markets[marketId].createdAtBlock;
    }

    function getTotalStakers(uint256 marketId) external view returns (uint256 yesCount, uint256 noCount) {
        if (marketId == 0 || marketId > marketCount) return (0, 0);
        yesCount = markets[marketId].totalStakersYes;
        noCount = markets[marketId].totalStakersNo;
    }

    function stakeCounter() external view returns (uint256) {
        return _stakeCounter;
    }

    function marketIdListLength() external view returns (uint256) {
        return _marketIdList.length;
    }

    function getMarketIdsActiveBeforeBlock(uint256 beforeBlock) external view returns (uint256[] memory ids) {
        uint256 n = 0;
        for (uint256 i = 0; i < _marketIdList.length; i++) {
            uint256 id = _marketIdList[i];
            if (!markets[id].resolved && markets[id].resolutionBlock > beforeBlock) n++;
        }
        ids = new uint256[](n);
        uint256 j = 0;
        for (uint256 i = 0; i < _marketIdList.length; i++) {
            uint256 id = _marketIdList[i];
            if (!markets[id].resolved && markets[id].resolutionBlock > beforeBlock) {
                ids[j] = id;
                j++;
            }
        }
    }

    function getStakerTotalStakedYes(address staker) external view returns (uint256 total) {
        uint256[] storage ids = stakeIdsByStaker[staker];
        for (uint256 i = 0; i < ids.length; i++) {
            if (stakes[ids[i]].outcome == 1) total += stakes[ids[i]].amountWei;
        }
    }

    function getStakerTotalStakedNo(address staker) external view returns (uint256 total) {
        uint256[] storage ids = stakeIdsByStaker[staker];
        for (uint256 i = 0; i < ids.length; i++) {
            if (stakes[ids[i]].outcome == 0) total += stakes[ids[i]].amountWei;
        }
    }

    function getStakerStakesOnMarket(address staker, uint256 marketId) external view returns (
        uint256[] memory stakeIdsOut,
        uint8[] memory outcomes,
        uint256[] memory amountWeis
    ) {
        uint256[] storage allIds = stakeIdsByStaker[staker];
        uint256 n = 0;
        for (uint256 i = 0; i < allIds.length; i++) {
            if (stakes[allIds[i]].marketId == marketId) n++;
        }
        stakeIdsOut = new uint256[](n);
        outcomes = new uint8[](n);
        amountWeis = new uint256[](n);
        uint256 j = 0;
        for (uint256 i = 0; i < allIds.length; i++) {
            if (stakes[allIds[i]].marketId == marketId) {
                stakeIdsOut[j] = allIds[i];
                outcomes[j] = stakes[allIds[i]].outcome;
                amountWeis[j] = stakes[allIds[i]].amountWei;
                j++;
            }
        }
    }

    function getMarketTotalStakes(uint256 marketId) external view returns (uint256) {
        return stakeIdsByMarket[marketId].length;
    }

    function getBlocksUntilResolution(uint256 marketId) external view returns (uint256) {
        if (marketId == 0 || marketId > marketCount) return type(uint256).max;
        ForecastMarket storage m = markets[marketId];
        if (m.resolved) return 0;
        if (block.number >= m.resolutionBlock) return 0;
        return m.resolutionBlock - block.number;
    }

    function getBlocksUntilResolvable(uint256 marketId) external view returns (uint256) {
        if (marketId == 0 || marketId > marketCount) return type(uint256).max;
        ForecastMarket storage m = markets[marketId];
        if (m.resolved) return 0;
        uint256 target = m.resolutionBlock + RESOLUTION_DELAY_BLOCKS;
        if (block.number >= target) return 0;
        return target - block.number;
    }

    function getMarketSummary(uint256 marketId) external view returns (
        bool resolved,
        uint8 winningOutcome,
        uint256 poolYesWei,
        uint256 poolNoWei,
        uint256 resolutionBlock,
        uint256 stakeCount
    ) {
        if (marketId == 0 || marketId > marketCount) return (false, 2, 0, 0, 0, 0);
        ForecastMarket storage m = markets[marketId];
        resolved = m.resolved;
        winningOutcome = m.winningOutcome;
        poolYesWei = m.poolYesWei;
        poolNoWei = m.poolNoWei;
        resolutionBlock = m.resolutionBlock;
        stakeCount = stakeIdsByMarket[marketId].length;
    }

    function getStakeIdsForMarketAndStaker(uint256 marketId, address staker) external view returns (uint256[] memory ids) {
        uint256[] storage all = stakeIdsByStaker[staker];
        uint256 n = 0;
        for (uint256 i = 0; i < all.length; i++) {
            if (stakes[all[i]].marketId == marketId) n++;
        }
        ids = new uint256[](n);
        uint256 j = 0;
        for (uint256 i = 0; i < all.length; i++) {
            if (stakes[all[i]].marketId == marketId) {
                ids[j] = all[i];
                j++;
            }
        }
    }

    function getClaimableMarketsForStaker(address staker) external view returns (uint256[] memory marketIds) {
        uint256 n = 0;
        for (uint256 i = 1; i <= marketCount; i++) {
            ForecastMarket storage m = markets[i];
            if (!m.resolved) continue;
            if (hasClaimedMarket[i][staker]) continue;
            uint256 myStake = m.winningOutcome == 1
                ? stakeAmountYesByMarket[i][staker]
                : stakeAmountNoByMarket[i][staker];
            if (myStake > 0) n++;
        }
        marketIds = new uint256[](n);
        uint256 j = 0;
        for (uint256 i = 1; i <= marketCount; i++) {
            ForecastMarket storage m = markets[i];
            if (!m.resolved) continue;
            if (hasClaimedMarket[i][staker]) continue;
            uint256 myStake = m.winningOutcome == 1
                ? stakeAmountYesByMarket[i][staker]
                : stakeAmountNoByMarket[i][staker];
            if (myStake > 0) {
                marketIds[j] = i;
                j++;
            }
        }
    }

    function getMarketIdsCreatedBy(address creator) external view returns (uint256[] memory) {
        return marketIdsByCreator[creator];
    }

    function getFirstNMarketIds(uint256 n) external view returns (uint256[] memory ids) {
        if (n > _marketIdList.length) n = _marketIdList.length;
        ids = new uint256[](n);
        for (uint256 i = 0; i < n; i++) ids[i] = _marketIdList[i];
    }

    function getLastNMarketIds(uint256 n) external view returns (uint256[] memory ids) {
        uint256 len = _marketIdList.length;
        if (n > len) n = len;
        ids = new uint256[](n);
        for (uint256 i = 0; i < n; i++) ids[i] = _marketIdList[len - 1 - i];
    }

    function getResolvedMarketIds() external view returns (uint256[] memory ids) {
        uint256 n = 0;
        for (uint256 i = 1; i <= marketCount; i++) {
            if (markets[i].resolved) n++;
        }
        ids = new uint256[](n);
        uint256 j = 0;
        for (uint256 i = 1; i <= marketCount; i++) {
            if (markets[i].resolved) {
                ids[j] = i;
                j++;
            }
        }
    }

    function getOpenMarketIds() external view returns (uint256[] memory ids) {
        uint256 n = 0;
        for (uint256 i = 1; i <= marketCount; i++) {
            if (!markets[i].resolved && block.number < markets[i].resolutionBlock) n++;
        }
        ids = new uint256[](n);
        uint256 j = 0;
        for (uint256 i = 1; i <= marketCount; i++) {
            if (!markets[i].resolved && block.number < markets[i].resolutionBlock) {
                ids[j] = i;
                j++;
            }
        }
    }

    function getProtocolBalance() external view returns (uint256) {
        return address(this).balance;
    }

    function getFeeAccrued() external view returns (uint256) {
        return totalFeesWei;
    }

    function getVolumeToDate() external view returns (uint256) {
        return totalStakeVolumeWei;
    }

    function getPayoutsToDate() external view returns (uint256) {
        return totalPayoutsWei;
    }

    function isStakeClaimed(uint256 stakeId) external view returns (bool) {
        if (stakeId == 0 || stakeId > _stakeCounter) return false;
        uint256 marketId = stakes[stakeId].marketId;
        return hasClaimedMarket[marketId][stakes[stakeId].staker];
    }

    function getStakeOutcome(uint256 stakeId) external view returns (uint8) {
        if (stakeId == 0 || stakeId > _stakeCounter) return 2;
        return stakes[stakeId].outcome;
    }

    function getStakeAmount(uint256 stakeId) external view returns (uint256) {
        if (stakeId == 0 || stakeId > _stakeCounter) return 0;
        return stakes[stakeId].amountWei;
    }

    function getStakeStaker(uint256 stakeId) external view returns (address) {
        if (stakeId == 0 || stakeId > _stakeCounter) return address(0);
        return stakes[stakeId].staker;
    }

    function getStakeMarketId(uint256 stakeId) external view returns (uint256) {
        if (stakeId == 0 || stakeId > _stakeCounter) return 0;
        return stakes[stakeId].marketId;
    }

    function getMarketQuestionHash(uint256 marketId) external view returns (bytes32) {
        if (marketId == 0 || marketId > marketCount) return bytes32(0);
        return markets[marketId].questionHash;
    }

    function getMarketResolutionBlock(uint256 marketId) external view returns (uint256) {
        if (marketId == 0 || marketId > marketCount) return 0;
        return markets[marketId].resolutionBlock;
    }

    function getMarketCreatorAddress(uint256 marketId) external view returns (address) {
        if (marketId == 0 || marketId > marketCount) return address(0);
        return markets[marketId].creator;
    }

    function getMarketResolvedFlag(uint256 marketId) external view returns (bool) {
        if (marketId == 0 || marketId > marketCount) return false;
        return markets[marketId].resolved;
    }

    function getMarketWinningOutcome(uint256 marketId) external view returns (uint8) {
        if (marketId == 0 || marketId > marketCount) return 2;
        return markets[marketId].winningOutcome;
    }

    function getMarketPoolYes(uint256 marketId) external view returns (uint256) {
        if (marketId == 0 || marketId > marketCount) return 0;
        return markets[marketId].poolYesWei;
    }

    function getMarketPoolNo(uint256 marketId) external view returns (uint256) {
        if (marketId == 0 || marketId > marketCount) return 0;
        return markets[marketId].poolNoWei;
    }

    function getMarketCreatedAtBlock(uint256 marketId) external view returns (uint256) {
        if (marketId == 0 || marketId > marketCount) return 0;
        return markets[marketId].createdAtBlock;
    }

    function getFullMarketSnapshot(uint256 marketId) external view returns (
        bytes32 qHash,
        uint256 resBlock,
        uint256 createdBlock,
        address creatorAddr,
        uint8 winning,
        bool isResolved,
        uint256 yesPool,
        uint256 noPool,
        uint256 stakersYes,
        uint256 stakersNo,
        uint256 numStakes
    ) {
        if (marketId == 0 || marketId > marketCount) return (bytes32(0), 0, 0, address(0), 2, false, 0, 0, 0, 0, 0);
        ForecastMarket storage m = markets[marketId];
        qHash = m.questionHash;
