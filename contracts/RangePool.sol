// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.7.5;

import "./libraries/SafeERC20.sol";
import "./libraries/Address.sol";

import "./types/ERC20.sol";
import "./types/Ownable.sol";

import "./interfaces/IOwnable.sol";

/**
 * Range Pool is a RangeSwap ERC20 token that facilitates trades between stablecoins. We execute "optimistic swaps" --
 * essentially, the pool assumes all tokens to be worth the same amount at all times, and executes as such.
 * The caveat is that tokens must remain within a range, determined by Allocation Points (AP). For example,
 * token A with (lowAP = 1e8) and (highAP = 5e8) must make up 10%-50% of the pool at all times.
 * RangeSwap allows for cheaper execution and higher capital efficiency than existing, priced swap protocols.
 */
contract RangePool is ERC20, Ownable {

    using SafeMath for uint;
    using SafeERC20 for IERC20;
    using SafeERC20 for ERC20;
    using Address for address;


    /* ========== EVENTS ========== */

    event Swap( address, uint, address );
    event Add( address, uint );
    event Remove( address, uint );

    event TokenAdded( address, uint, uint );
    event BoundsChanged( address, uint, uint );
    event Accepting( address, bool );
    event FeeChanged( uint );


    /* ========== STRUCTS ========== */

    struct PoolToken {
        uint lowAP; // 9 decimals
        uint highAP; // 9 decimals
        bool accepting; // can send in (swap or add)
        bool pushed; // pushed to tokens list
    }


    /* ========== STATE VARIABLES ========== */

    mapping( address => PoolToken ) public tokenInfo;
    address[] public tokens;
    uint public totalTokens;

    uint public fee; // 9 decimals
    
    constructor() ERC20( 'Range Pool Token', 'RPT' ) {
        _mint( msg.sender, 1e18 );
        totalTokens = 1e18;
    }

    /* ========== SWAP ========== */

    // swap amount from firstToken to secondToken
    function swap( address firstToken, uint amount, address secondToken ) external {
        require( amount <= maxCanSwap( firstToken, secondToken ), "Exceeds limit" );

        emit Swap( firstToken, amount, secondToken );

        uint feeToTake = amount.mul(fee).div(1e9);
        totalTokens = totalTokens.add( feeToTake );

        IERC20( firstToken ).safeTransferFrom( msg.sender, address(this), amount ); 
        IERC20( secondToken ).safeTransfer( msg.sender, amount.sub( feeToTake ) ); // take fee on amount
    }

    /* ========== ADD LIQUIDITY ========== */

    // add token to pool as liquidity. returns number of pool tokens minted.
    function add( address token, uint amount ) external returns ( uint amount_ ) {
        amount_ = value( amount ); // do this before changing totalTokens or totalSupply

        totalTokens = totalTokens.add( amount ); // add amount to total first

        require( amount <= maxCanAdd( token ), "Exceeds limit" );

        IERC20( token ).safeTransferFrom( msg.sender, address(this), amount );
        emit Add( token, amount );

        _mint( msg.sender, amount_ );
    }

    // add liquidity evenly across all tokens. returns number of pool tokens minted.
    function addAll( uint amount ) external returns ( uint amount_ ) {
        uint sum;
        for ( uint i = 0; i < tokens.length; i++ ) {
            IERC20 token = IERC20( tokens[i] );
            uint send = amount.mul( token.balanceOf( address(this) ) ).div( totalTokens );
            if (send > 0) {
                token.safeTransferFrom( msg.sender, address(this), send );
                emit Add( tokens[i], send );
                sum = sum.add(send);
            }
        }
        amount_ = value( sum );

        totalTokens = totalTokens.add( sum ); // add amount second (to not skew pool)
        _mint( msg.sender, amount_ );
    }

    /* ========== REMOVE LIQUIDITY ========== */

    // remove token from liquidity, burning pool token
    // pass in amount token to remove, returns amount_ pool tokens burned
    function remove( address token, uint amount ) external returns (uint amount_) {
        amount_ = value( amount ); // token balance => pool token balance
        amount = amount.sub( amount.mul( fee ).div( 1e9 ) ); // take fee

        require( amount <= maxCanRemove( token ), "Exceeds limit" );
        emit Remove( token, amount );

        _burn( msg.sender, amount_ ); // burn pool token
        totalTokens = totalTokens.sub( amount ); // remove amount from pool less fees

        IERC20( token ).safeTransfer( msg.sender, amount ); // send token removed
    }

    // remove liquidity evenly across all tokens 
    // pass in amount tokens to remove, returns amount_ pool tokens burned
    function removeAll( uint amount ) public returns (uint amount_) {
        uint sum;
        for ( uint i = 0; i < tokens.length; i++ ) {
            IERC20 token = IERC20( tokens[i] );
            uint send = amount.mul( token.balanceOf( address(this) ) ).div( totalTokens );

            if ( send > 0 ) {
                uint minusFee = send.sub( send.mul( fee ).div( 1e9 ) );
                token.safeTransfer( msg.sender, minusFee );
                emit Remove( tokens[i], minusFee ); // take fee
                sum = sum.add(send);
            }
        }

        amount_ = value( sum );
        _burn( msg.sender, amount_ );
        totalTokens = totalTokens.sub( sum.sub( sum.mul( fee ).div( 1e9 ) ) ); // remove amount from pool less fees
    }

    /* ========== VIEW FUNCTIONS ========== */

    // number of tokens 1 pool token can be redeemed for
    function redemptionValue() public view returns (uint value_) {
        value_ = totalTokens.mul(1e18).div( totalSupply() );
    } 

    // token value => pool token value
    function value( uint amount ) public view returns ( uint ) {
        return amount.mul( 1e18 ).div( redemptionValue() );
    }

    // maximum number of token that can be added to pool
    function maxCanAdd( address token ) public view returns ( uint ) {
        require( tokenInfo[token].accepting, "Not accepting token" );
        uint maximum = totalTokens.mul( tokenInfo[ token ].highAP ).div( 1e9 );
        uint balance = IERC20( token ).balanceOf( address(this) );
        return maximum.sub( balance );
    }

    // maximum number of token that can be removed from pool
    function maxCanRemove( address token ) public view returns ( uint ) {
        uint minimum = totalTokens.mul( tokenInfo[ token ].lowAP ).div( 1e9 );
        uint balance = IERC20( token ).balanceOf( address(this) );
        return balance.sub( minimum );
    }

    // maximum size of trade from first token to second token
    function maxCanSwap( address firstToken, address secondToken ) public view returns ( uint ) {
        uint canAdd = maxCanAdd( firstToken);
        uint canRemove = maxCanRemove( secondToken );

        if ( canAdd > canRemove ) {
            return canRemove;
        } else {
            return canAdd;
        }
    }

    // amount of secondToken returned by swap
    function amountOut( address firstToken, uint amount, address secondToken ) external view returns ( uint ) {
        if ( amount <= maxCanSwap( firstToken, secondToken ) ) {
            return amount.sub( amount.mul( fee ).div( 1e9 ) );
        } else {
            return 0;
        }
    }

    /* ========== SETTINGS ========== */

    // set fee taken on trades
    function setFee( uint newFee ) external onlyOwner() {
        fee = newFee;
        emit FeeChanged( fee );
    }

    // add new token to pool. allocation points are 9 decimals.
    // must call toggleAccept to activate token
    function addToken( address token, uint lowAP, uint highAP ) external onlyOwner() {
        require( !tokenInfo[ token ].pushed );

        tokenInfo[ token ] = PoolToken({
            lowAP: lowAP,
            highAP: highAP,
            accepting: false,
            pushed: true
        });

        tokens.push( token );
        emit TokenAdded( token, lowAP, highAP );
    }

    // change bounds of tokens in pool
    function changeBound( address token, uint newLow, uint newHigh ) external onlyOwner() {
        tokenInfo[ token ].highAP = newHigh;
        tokenInfo[ token ].lowAP = newLow;

        emit BoundsChanged( token, newLow, newHigh );
    }

    // toggle whether to accept incoming token
    // setting token to false will not allow swaps as incoming token or adds
    function toggleAccept( address token ) external onlyOwner() {
        tokenInfo[ token ].accepting = !tokenInfo[ token ].accepting;
        emit Accepting( token, tokenInfo[ token ].accepting );
    }
}