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
