pragma solidity ^0.8.6;

import "ds-test/test.sol";

import "./GebVestedEscrowedToken.sol";

contract GebVestedEscrowedTokenTest is DSTest {
    GebVestedEscrowedToken token;

    function setUp() public {
        token = new GebVestedEscrowedToken();
    }

    function testFail_basic_sanity() public {
        assertTrue(false);
    }

    function test_basic_sanity() public {
        assertTrue(true);
    }
}
