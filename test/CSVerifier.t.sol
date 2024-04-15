// SPDX-FileCopyrightText: 2023 Lido <info@lido.fi>
// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import { stdJson } from "forge-std/StdJson.sol";

import { ILidoLocator } from "../src/interfaces/ILidoLocator.sol";
import { ICSVerifier } from "../src/interfaces/ICSVerifier.sol";
import { ICSModule } from "../src/interfaces/ICSModule.sol";

import { CSVerifier } from "../src/CSVerifier.sol";
import { pack } from "../src/lib/GIndex.sol";
import { Slot } from "../src/lib/Types.sol";

import { Stub } from "./helpers/mocks/Stub.sol";

contract CSVerifierTest is Test {
    using stdJson for string;

    struct WithdrawalFixture {
        bytes32 _blockRoot;
        bytes _pubkey;
        address _withdrawalAddress;
        ICSVerifier.ProvableBeaconBlockHeader beaconBlock;
        ICSVerifier.WithdrawalWitness witness;
    }

    struct SlashingFixture {
        bytes32 _blockRoot;
        bytes _pubkey;
        ICSVerifier.ProvableBeaconBlockHeader beaconBlock;
        ICSVerifier.SlashingWitness witness;
    }

    // On **prater**, see https://github.com/eth-clients/goerli/blob/main/prater/config.yaml.
    uint64 public constant DENEB_FORK_EPOCH = 231680;

    CSVerifier public verifier;
    Stub public locator;
    Stub public module;

    string internal fixturesPath = "./test/fixtures/CSVerifier/";

    function setUp() public {
        verifier = new CSVerifier({
            slotsPerEpoch: 32,
            gIHistoricalSummaries: pack(0x0, 0), // We don't care of the value for this test.
            gIFirstWithdrawal: pack(0xe1c0, 4),
            gIFirstValidator: pack(0x560000000000, 40),
            // TODO: Fix proofs and set Slot.wrap(DENEB_FORK_EPOCH * 32)
            firstSupportedSlot: Slot.wrap(1357000)
        });

        locator = new Stub();
        module = new Stub();

        verifier.initialize(address(locator), address(module));
    }

    function test_processSlashingProof() public {
        SlashingFixture memory fixture = abi.decode(
            _readFixture("slashing.json"),
            (SlashingFixture)
        );

        _setMocksSlashing(fixture);

        verifier.processSlashingProof(
            fixture.beaconBlock,
            fixture.witness,
            0,
            0
        );
    }

    function test_processSlashingProof_RevertWhen_UnsupportedSlot() public {
        SlashingFixture memory fixture = abi.decode(
            _readFixture("slashing.json"),
            (SlashingFixture)
        );

        _setMocksSlashing(fixture);

        fixture.beaconBlock.header.slot =
            verifier.FIRST_SUPPORTED_SLOT().unwrap() -
            1;

        vm.expectRevert(
            abi.encodeWithSelector(
                CSVerifier.UnsupportedSlot.selector,
                fixture.beaconBlock.header.slot
            )
        );
        verifier.processSlashingProof(
            fixture.beaconBlock,
            fixture.witness,
            0,
            0
        );
    }

    function test_processSlashingProof_RevertWhen_InvalidBlockHeader() public {
        SlashingFixture memory fixture = abi.decode(
            _readFixture("slashing.json"),
            (SlashingFixture)
        );

        _setMocksSlashing(fixture);

        vm.mockCall(
            verifier.BEACON_ROOTS(),
            abi.encode(fixture.beaconBlock.rootsTimestamp),
            abi.encode("lol")
        );

        vm.expectRevert(CSVerifier.InvalidBlockHeader.selector);
        verifier.processSlashingProof(
            fixture.beaconBlock,
            fixture.witness,
            0,
            0
        );
    }

    function test_processWithdrawalProof() public {
        WithdrawalFixture memory fixture = abi.decode(
            _readFixture("withdrawal.json"),
            (WithdrawalFixture)
        );

        _setMocksWithdrawal(fixture);

        verifier.processWithdrawalProof(
            fixture.beaconBlock,
            fixture.witness,
            0,
            0
        );
    }

    function test_processWithdrawalProof_ZeroWithrawalIndex() public {
        WithdrawalFixture memory fixture = abi.decode(
            _readFixture("withdrawal_zero_index.json"),
            (WithdrawalFixture)
        );

        _setMocksWithdrawal(fixture);

        verifier.processWithdrawalProof(
            fixture.beaconBlock,
            fixture.witness,
            0,
            0
        );
    }

    function test_processWithdrawalProof_RevertWhen_UnsupportedSlot() public {
        WithdrawalFixture memory fixture = abi.decode(
            _readFixture("withdrawal.json"),
            (WithdrawalFixture)
        );

        _setMocksWithdrawal(fixture);

        fixture.beaconBlock.header.slot =
            verifier.FIRST_SUPPORTED_SLOT().unwrap() -
            1;

        vm.expectRevert(
            abi.encodeWithSelector(
                CSVerifier.UnsupportedSlot.selector,
                fixture.beaconBlock.header.slot
            )
        );
        verifier.processWithdrawalProof(
            fixture.beaconBlock,
            fixture.witness,
            0,
            0
        );
    }

    function test_processWithdrawalProof_RevertWhen_InvalidBlockHeader()
        public
    {
        WithdrawalFixture memory fixture = abi.decode(
            _readFixture("withdrawal.json"),
            (WithdrawalFixture)
        );

        _setMocksWithdrawal(fixture);

        vm.mockCall(
            verifier.BEACON_ROOTS(),
            abi.encode(fixture.beaconBlock.rootsTimestamp),
            abi.encode("lol")
        );

        vm.expectRevert(CSVerifier.InvalidBlockHeader.selector);
        verifier.processWithdrawalProof(
            fixture.beaconBlock,
            fixture.witness,
            0,
            0
        );
    }

    function test_processWithdrawalProof_RevertWhen_No4788Contract() public {
        WithdrawalFixture memory fixture = abi.decode(
            _readFixture("withdrawal.json"),
            (WithdrawalFixture)
        );

        vm.mockCall(
            address(module),
            abi.encodeWithSelector(
                ICSModule.getNodeOperatorSigningKeys.selector,
                0,
                0
            ),
            abi.encode(fixture._pubkey)
        );

        vm.mockCall(
            address(locator),
            abi.encodeWithSelector(ILidoLocator.withdrawalVault.selector),
            abi.encode(fixture._withdrawalAddress)
        );

        vm.mockCall(
            address(module),
            abi.encodeWithSelector(ICSModule.submitWithdrawal.selector),
            ""
        );

        vm.etch(verifier.BEACON_ROOTS(), new bytes(0));

        vm.expectRevert(CSVerifier.RootNotFound.selector);
        verifier.processWithdrawalProof(
            fixture.beaconBlock,
            fixture.witness,
            0,
            0
        );
    }

    function test_processWithdrawalProof_RevertWhen_revertFrom4788() public {
        WithdrawalFixture memory fixture = abi.decode(
            _readFixture("withdrawal.json"),
            (WithdrawalFixture)
        );

        _setMocksWithdrawal(fixture);

        vm.mockCallRevert(
            verifier.BEACON_ROOTS(),
            abi.encode(fixture.beaconBlock.rootsTimestamp),
            ""
        );

        vm.expectRevert(CSVerifier.RootNotFound.selector);
        verifier.processWithdrawalProof(
            fixture.beaconBlock,
            fixture.witness,
            0,
            0
        );
    }

    function _readFixture(
        string memory filename
    ) internal noGasMetering returns (bytes memory data) {
        string memory path = string.concat(fixturesPath, filename);
        string memory json = vm.readFile(path);
        data = json.parseRaw("$");
    }

    function _setMocksSlashing(SlashingFixture memory fixture) internal {
        vm.mockCall(
            verifier.BEACON_ROOTS(),
            abi.encode(fixture.beaconBlock.rootsTimestamp),
            abi.encode(fixture._blockRoot)
        );

        vm.mockCall(
            address(module),
            abi.encodeWithSelector(
                ICSModule.getNodeOperatorSigningKeys.selector,
                0,
                0
            ),
            abi.encode(fixture._pubkey)
        );

        vm.mockCall(
            address(module),
            abi.encodeWithSelector(ICSModule.submitInitialSlashing.selector),
            ""
        );
    }

    function test_processWithdrawalProof_RevertWhen_InvalidWithdrawalAddress()
        public
    {
        WithdrawalFixture memory fixture = abi.decode(
            _readFixture("withdrawal.json"),
            (WithdrawalFixture)
        );

        _setMocksWithdrawal(fixture);

        fixture.witness.withdrawalCredentials = bytes32(0);

        vm.expectRevert(CSVerifier.InvalidWithdrawalAddress.selector);
        verifier.processWithdrawalProof(
            fixture.beaconBlock,
            fixture.witness,
            0,
            0
        );
    }

    function test_processWithdrawalProof_RevertWhen_ValidatorNotWithdrawn()
        public
    {
        WithdrawalFixture memory fixture = abi.decode(
            _readFixture("withdrawal.json"),
            (WithdrawalFixture)
        );

        _setMocksWithdrawal(fixture);

        fixture.witness.withdrawableEpoch =
            fixture.beaconBlock.header.slot /
            32 +
            154;

        vm.expectRevert(CSVerifier.ValidatorNotWithdrawn.selector);
        verifier.processWithdrawalProof(
            fixture.beaconBlock,
            fixture.witness,
            0,
            0
        );
    }

    function test_processWithdrawalProof_RevertWhen_PartialWitdrawal() public {
        WithdrawalFixture memory fixture = abi.decode(
            _readFixture("withdrawal.json"),
            (WithdrawalFixture)
        );

        _setMocksWithdrawal(fixture);

        fixture.witness.amount = 154;

        vm.expectRevert(CSVerifier.PartialWitdrawal.selector);
        verifier.processWithdrawalProof(
            fixture.beaconBlock,
            fixture.witness,
            0,
            0
        );
    }

    function _setMocksWithdrawal(WithdrawalFixture memory fixture) internal {
        vm.mockCall(
            verifier.BEACON_ROOTS(),
            abi.encode(fixture.beaconBlock.rootsTimestamp),
            abi.encode(fixture._blockRoot)
        );

        vm.mockCall(
            address(module),
            abi.encodeWithSelector(
                ICSModule.getNodeOperatorSigningKeys.selector,
                0,
                0
            ),
            abi.encode(fixture._pubkey)
        );

        vm.mockCall(
            address(locator),
            abi.encodeWithSelector(ILidoLocator.withdrawalVault.selector),
            abi.encode(fixture._withdrawalAddress)
        );

        vm.mockCall(
            address(module),
            abi.encodeWithSelector(ICSModule.submitWithdrawal.selector),
            ""
        );
    }
}
