// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.7.6;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "./InterestToken.sol";
import "./PowerToken.sol";
import "./ExpMath.sol";

contract RentingPool is Ownable {
    using SafeERC20 for ERC20;

    struct Service {
        uint32[] allowedLoanDurations;
        uint8[] allowedRefundCurvatures;
        uint256 borrowed;
        uint112 factor;
        uint32 lastDeal;
        uint32 interestRateHalvingPeriod;
        // demand, borrowing rate, volumes
    }

    struct State {
        uint112 plannedBalance;
        uint112 acquiredBalance;
        uint32 timestamp;
    }

    ERC20 public liquidityToken;
    InterestToken public iToken;
    uint256 public reserve;
    uint256 public availableReserve;
    string public baseUri;
    mapping(PowerToken => Service) public services;
    mapping(address => mapping(uint32 => mapping(uint8 => State))) public states;
    mapping(address => int16) public supportedInterestTokensIndex;
    address[] public supportedInterestTokens;

    constructor(ERC20 _liquidityToken, string memory _baseUri) {
        liquidityToken = _liquidityToken;
        baseUri = _baseUri;
        _enableInterestToken(address(_liquidityToken));
    }

    function registerService(
        string memory _name,
        string memory _symbol,
        uint32 _halfLife,
        uint112 _factor,
        uint32 _interestRateHalvingPeriod,
        uint32[] memory _allowedLoanDurations,
        uint8[] memory _allowedRefundCurvatures
    ) public {
        string memory tokenSymbol = liquidityToken.symbol();
        string memory powerTokenSymbol = string(abi.encodePacked(tokenSymbol, " ", _symbol));

        PowerToken powerToken = new PowerToken(_name, powerTokenSymbol, baseUri, _halfLife);

        services[powerToken].allowedLoanDurations = _allowedLoanDurations;
        services[powerToken].allowedRefundCurvatures = _allowedRefundCurvatures;
        services[powerToken].factor = _factor;
        services[powerToken].interestRateHalvingPeriod = _interestRateHalvingPeriod;
    }

    function borrow(
        PowerToken _powerToken,
        ERC20 _interestPaymentToken,
        uint112 _amount,
        uint256 _maximumInterest,
        uint32 _duration,
        uint8 _refundCurvature
    ) external {
        require(
            supportedInterestTokensIndex[address(_interestPaymentToken)] > 0,
            "Interest payment token is disabled or not supported"
        );
        require(isAllowedLoanDuration(_powerToken, _duration), "Duration not allowed");
        require(isAllowedRefundCurvatures(_powerToken, _refundCurvature), "Curvature not allowed");
        require(availableReserve >= _amount, "Insufficient reserves");

        uint112 interest =
            estimateBorrow(
                _powerToken,
                _interestPaymentToken,
                _amount,
                _duration,
                _refundCurvature,
                uint32(block.timestamp)
            );
        require(interest <= _maximumInterest, "Slippage too big");

        _interestPaymentToken.safeTransferFrom(msg.sender, address(this), interest);

        availableReserve -= _amount;
        services[_powerToken].borrowed += _amount;

        uint256 tokenId =
            _getTokenId(
                uint32(block.timestamp),
                uint32(block.timestamp) + _duration,
                _refundCurvature,
                uint16(supportedInterestTokensIndex[address(_interestPaymentToken)]),
                interest
            );

        _powerToken.mint(msg.sender, tokenId, _amount, "");

        State storage state = _updateState(tokenId);
        state.plannedBalance += interest;
    }

    function estimateBorrow(
        PowerToken _powerToken,
        ERC20 _interestPaymentToken,
        uint112 _amount,
        uint32 _duration,
        uint8 _refundCurvature,
        uint32 _estimateAtTimestamp
    ) public view returns (uint112) {
        require(isAllowedLoanDuration(_powerToken, _duration), "Duration not allowed");
        require(isAllowedRefundCurvatures(_powerToken, _refundCurvature), "Curvature not allowed");
        require(_amount > availableReserve, "Too low available reserves");

        Service storage service = services[_powerToken];

        uint112 C0 = uint112((uint256(_amount) * _duration * service.factor) >> (112 - _refundCurvature));
        uint112 halfLife =
            ExpMath.halfLife(service.lastDeal, C0, service.interestRateHalvingPeriod, _estimateAtTimestamp);

        // TODO: SafeMath, analyze bits
        uint256 UintInterestInLiquidityTokens = (halfLife * reserve) / (availableReserve - _amount);
        uint112 interestInLiquidityTokens =
            UintInterestInLiquidityTokens > type(uint112).max
                ? type(uint112).max
                : uint112(UintInterestInLiquidityTokens);

        return convert(interestInLiquidityTokens, _interestPaymentToken);
    }

    function burn(
        PowerToken _powerToken,
        uint256 _tokenId,
        uint112 _amount
    ) external {
        uint256 balance = _powerToken.balanceOf(msg.sender, _tokenId);
        require(_amount <= balance, "Can't burn more that balance");

        (address paymentToken, uint112 refund) =
            estimateRefund(_powerToken, msg.sender, _tokenId, _amount, uint32(block.timestamp));

        State storage state = _updateState(_tokenId);
        state.plannedBalance -= refund;

        availableReserve += _amount;
        services[_powerToken].borrowed -= _amount;

        ERC20(paymentToken).safeTransfer(msg.sender, refund);

        _powerToken.burn(msg.sender, _tokenId, refund);
    }

    function estimateRefund(
        PowerToken _powerToken,
        address _tokenHolder,
        uint256 _tokenId,
        uint112 _amountToBurn,
        uint32 _estimateAt
    ) public view returns (address paymentToken, uint112 amount) {
        (uint32 from, uint32 to, uint8 curvature, uint16 tokenIndex, uint112 interest) = _extractTokenId(_tokenId);
        paymentToken = supportedInterestTokens[tokenIndex];

        uint256 balance = _powerToken.balanceOf(_tokenHolder, _tokenId);
        if (balance == 0) {
            return (paymentToken, 0);
        }

        amount = uint112(
            (ExpMath.halfLife(uint32(from), interest, uint32(to - from) / curvature, _estimateAt) * _amountToBurn) /
                balance
        );
    }

    function convert(uint112 _liquidityAmount, ERC20 _payment) internal view returns (uint112) {
        //TODO: apply convertation
        require(address(_payment) == address(liquidityToken), "Other payment options are not supported yet");

        return _liquidityAmount;
    }

    function _updateState(uint256 _tokenId) internal returns (State storage state) {
        (uint32 from, uint32 to, uint8 curvature, uint16 tokenIndex, ) = _extractTokenId(_tokenId);
        address interestPaymentToken = supportedInterestTokens[tokenIndex];
        uint32 duration = uint32(to - from);

        state = states[interestPaymentToken][duration][curvature];
        state.acquiredBalance =
            state.plannedBalance -
            ExpMath.halfLife(
                state.timestamp,
                state.plannedBalance - state.acquiredBalance,
                duration / curvature,
                uint32(block.timestamp - state.timestamp)
            );
        state.timestamp = uint32(block.timestamp);
    }

    function _getTokenId(
        uint32 _from,
        uint32 _to,
        uint8 _curvature,
        uint16 _tokenIndex,
        uint112 _interest
    ) internal pure returns (uint256 _tokenId) {
        _tokenId =
            (uint256(_from) << 224) |
            (uint256(_to) << 192) |
            (uint256(_curvature) << 184) |
            (uint256(_tokenIndex) << 168) |
            _interest;
    }

    function _extractTokenId(uint256 _tokenId)
        internal
        pure
        returns (
            uint32 from,
            uint32 to,
            uint8 curvature,
            uint16 tokenIndex,
            uint112 interest
        )
    {
        from = uint32((_tokenId >> 224) & type(uint32).max);
        to = uint32((_tokenId >> 192) & type(uint32).max);
        curvature = uint8((_tokenId >> 184) & type(uint8).max);
        tokenIndex = uint16((_tokenId >> 168) & type(uint16).max);
        interest = uint112(_tokenId & type(uint112).max);
        require(from > 0, "Invalid from");
        require(to > 0, "Invalid to");
        require(curvature > 0, "Invalid curvature");
        require(interest > 0, "Invalid interest");
    }

    function isAllowedLoanDuration(PowerToken _token, uint32 _duration) public view returns (bool) {
        Service storage service = services[_token];
        uint256 n = service.allowedLoanDurations.length;
        for (uint256 i = 0; i < n; i++) {
            if (service.allowedLoanDurations[i] == _duration) return true;
        }
        return false;
    }

    function isAllowedRefundCurvatures(PowerToken _token, uint8 curvature) public view returns (bool) {
        Service storage service = services[_token];
        uint256 n = service.allowedRefundCurvatures.length;
        for (uint256 i = 0; i < n; i++) {
            if (service.allowedRefundCurvatures[i] == curvature) return true;
        }
        return false;
    }

    function _enableInterestToken(address _token) internal {
        if (supportedInterestTokensIndex[_token] == 0) {
            supportedInterestTokens.push(_token);
            supportedInterestTokensIndex[_token] = int16(supportedInterestTokens.length);
        } else if (supportedInterestTokensIndex[_token] < 0) {
            supportedInterestTokensIndex[_token] = -supportedInterestTokensIndex[_token];
        }
    }

    function _disableInterestToken(address _token) internal {
        require(supportedInterestTokensIndex[_token] != 0, "Invalid token");

        if (supportedInterestTokensIndex[_token] > 0) {
            supportedInterestTokensIndex[_token] = -supportedInterestTokensIndex[_token];
        }
    }
}
