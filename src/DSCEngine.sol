//SPDX-License-Identifier: MIT

// This is considered an Exogenous, Decentralized, Anchored (pegged), Crypto Collateralized low volatility coin

// Layout of Contract:
// version
// imports
// interfaces, libraries, contracts
// errors
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions

pragma solidity ^0.8.19;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "lib/openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from
    "lib/chainlink-brownie-contracts/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title DSCEngine
 * @author Patrick Collins
 *
 * The system is designed to be as minimal as possible, and have the tokens maintain a 1 token == $1 peg at all times.
 * This is a stablecoin with the properties:
 * - Exogenously Collateralized
 * - Dollar Pegged
 * - Algorithmically Stable
 *
 * It is similar to DAI if DAI had no governance, no fees, and was backed by only WETH and WBTC.
 *
 * Our DSC system should always be "overcollateralized". At no point, should the value of
 * all collateral < the $ backed value of all the DSC.
 *
 * @notice This contract is the core of the Decentralized Stablecoin system. It handles all the logic
 * for minting and redeeming DSC, as well as depositing and withdrawing collateral.
 * @notice This contract is based on the MakerDAO DSS system
 */
contract DSCEngine is ReentrancyGuard {
    ////////////////
    //Errors///
    ///////////////
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine__NotAllowedToken(address token);
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorOk();

    ////////////////
    //State variable///
    ///////////////

    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 200% overcollateralized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1;
    uint256 private constant LIQUIDATION_BONUS = 10;

    mapping(address token => address priceFeed) private s_priceFeeds; //token address -> price feed address
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited; //user address -> (token address -> amount deposited)
    mapping(address user => uint256 amountDscMinted) private s_DSCMinted; //user address -> amount of DSC minted
    address[] private s_collateralTokens;
    DecentralizedStableCoin private immutable i_dsc;

    ////////////////
    //Events///
    ///////////////

    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(address indexed user, address indexed token, uint256 indexed amount);
    ////////////////
    //Modifiers///
    ///////////////

    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__NotAllowedToken(token);
        }
        _;
    }

    ////////////////
    //Functions///
    ///////////////

    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        //Usd price feed
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressAndPriceFeedAddressesMustBeSameLength();
        }

        ///For eg, ETH/USD/ETC's price feeds
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    ////////////////
    //Internal Functions///
    ////////////////

    //External Functions///
    /////////////////

    /*
 * @param tokenCollateralAddress: the address of the token to deposit as collateral
 * @param amountCollateral: The amount of collateral to deposit
 * @param amountDscToMint: The amount of DecentralizedStableCoin to mint
 * @notice: This function will deposit your collateral and mint DSC in one transaction
 */

    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        external
        moreThanZero(amountCollateral)
        nonReentrant
        isAllowedToken(tokenCollateralAddress)
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /*
  * @param tokenCollateralAddress: the collateral address to redeem
  * @param amountCollateral: amount of collateral to redeem
  * @param amountDscToBurn: amount of DSC to burn
  * This function burns DSC and redeems underlying collateral in one transaction
  */
     function redeemCollateralForDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn) external {
     burnDsc(amountDscToBurn);
     redeemCollateral(tokenCollateralAddress, amountCollateral);
      }

     function redeemCollateral(
        address tokenCollateralAddress, 
        uint256 amountCollateral
        ) external
        moreThanZero(amountCollateral)
        nonReentrant
        {
            s_collateralDeposited[msg.sender][tokenCollateralAddress] -= amountCollateral;
            emit CollateralRedeemed(msg.sender, tokenCollateralAddress, amountCollateral);
            bool success = IERC20(tokenCollateralAddress).transfer(msg.sender, amountCollateral);
            if (!success) {
                revert DSCEngine__TransferFailed();
                }
                _revertIfHealthFactorIsBroken(msg.sender);
        }

    /*
     * @notice follow CEI
     * @param amountDscToMint The amount of DSC to mint
    * @param they should have more collateral value than than the threashold
    */
    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        // Mint the DSC tokens
        s_DSCMinted[msg.sender] += amountDscToMint;
        //if they mint too much
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    function burnDsc(uint256 amount) public moreThanZero(amount) nonReentrant {
        s_DSCMinted[msg.sender] -= amount;
        bool burned = i_dsc.transferFrom(msg.sender, address(this), amount);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amount);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /*
 * @param collateral: The ERC20 token address of the collateral you're using to make the protocol solvent again.
 * This is collateral that you're going to take from the user who is insolvent.
 * In return, you have to burn your DSC to pay off their debt, but you don't pay off your own.
 * @param user: The user who is insolvent. They have to have a _healthFactor below MIN_HEALTH_FACTOR
 * @param debtToCover: The amount of DSC you want to burn to cover the user's debt.
 *
 * @notice: You can partially liquidate a user.
 * @notice: You will get a 10% LIQUIDATION_BONUS for taking the users funds.
 * @notice: This function working assumes that the protocol will be roughly 150% overcollateralized in order for this
 to work.
 * @notice: A known bug would be if the protocol was only 100% collateralized, we wouldn't be able to liquidate
 anyone.
 * For example, if the price of the collateral plummeted before anyone could be liquidated.
 */
    function liquidate(address collateral, address user, uint256 debtToCover) external moreThanZero(debtToCover) nonReentrant {
    uint256 startingUserHealthFactor = _healthFactor(user);
    if(startingUserHealthFactor > MIN_HEALTH_FACTOR){
        revert DSCEngine__HealthFactorOk();
    }

    uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
    uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION; 
    uint256 totalCollateralRedeemed = tokenAmountFromDebtCovered + bonusCollateral;
   }  

    function healthFactor() external view {}

    ///////////////////
    // Private/Internal Functions///
    ////////////////////

    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 CollateralValueInUsd)
    {
        //loop through each collateral token, get the amount they have deposited, and convert that to usd value
        //return total dsc minted, and total collateral value
        totalDscMinted = s_DSCMinted[user];
        CollateralValueInUsd = getAccountCollateralValue(user);
    }
    /*
    * Returns how close to liquidation a user is
    * If a user goes below 1, then they can be liquidated.
    */

    function _healthFactor(address user) private view returns (uint256) {
        //total DSC minted
        //total collateral value
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;

        //return (totalCollateralValueInUsd / totalDscMinted);
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        //if they don't have enough collateral, revert
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    ///////////////////
    // Public/extrenal view Functions///
    ////////////////////

    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        //price feed
        //decimals
        //return usd value
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        //1 eth = 1000 USD
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
    AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
    (, int256 price,,,) = priceFeed.latestRoundData();
    return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
     }
 }
