# ICSEarlyAdoption

[Git Source](https://github.com/lidofinance/community-staking-module/blob/ef5c94eed5211bf6c350512cf569895da670f26c/src/interfaces/ICSEarlyAdoption.sol)

## Functions

### CURVE_ID

```solidity
function CURVE_ID() external view returns (uint256);
```

### TREE_ROOT

```solidity
function TREE_ROOT() external view returns (bytes32);
```

### verifyProof

```solidity
function verifyProof(address addr, bytes32[] calldata proof) external view returns (bool);
```

### consume

```solidity
function consume(address sender, bytes32[] calldata proof) external;
```

### isConsumed

```solidity
function isConsumed(address sender) external view returns (bool);
```
