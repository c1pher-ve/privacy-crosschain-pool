// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

library Constants {
  uint256 constant SNARK_SCALAR_FIELD =
    21_888_242_871_839_275_222_246_405_745_257_275_088_548_364_400_416_034_343_698_204_186_575_808_495_617;

  address constant NATIVE_ASSET = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

  /// @notice Duration after which an undelivered cross-chain intent can be reclaimed
  uint256 constant CROSS_CHAIN_TIMEOUT = 7 days;

  /// @notice Number of synced source chain roots to keep in the circular buffer
  uint32 constant SOURCE_ROOT_HISTORY_SIZE = 64;
}

