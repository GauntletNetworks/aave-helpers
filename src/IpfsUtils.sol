// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;
import {Vm} from 'forge-std/Vm.sol';
import {console2} from 'forge-std/console2.sol';

library IpfsUtils {
  error FfiFailed();

  function ipfsHashFile(Vm vm, string memory filePath, bool upload) internal returns (bytes32) {
    string[] memory inputs = new string[](5);
    inputs[0] = 'npx';
    inputs[1] = '@bgd-labs/aave-cli@0.1.0';
    inputs[2] = 'ipfs';
    inputs[3] = filePath;
    if (upload) {
      inputs[4] = '-u';
    }
    Vm.FfiResult memory f = vm.tryFfi(inputs);
    if (f.exitCode != 0) {
      console2.logString(string(f.stderr));
      revert FfiFailed();
    }
    require(f.stdout.length != 0, 'CALCULATED_HASH_IS_ZERO');
    console2.logString('Info: This preview will only work when the file has been uploaded to ipfs');
    console2.logString(
      string(
        abi.encodePacked(
          'Preview: https://app.aave.com/governance/ipfs-preview/?ipfsHash=',
          vm.toString(f.stdout)
        )
      )
    );
    return bytes32(f.stdout);
  }
}
