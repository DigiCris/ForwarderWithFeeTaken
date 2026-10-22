// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {DummyVault} from "./DummyVault.sol";

/// @dev Second vault instance, used by the vault replacement rules.
contract DummyVault2 is DummyVault {}
