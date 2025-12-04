// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { FHE, euint32, ebool } from "@fhevm/solidity/lib/FHE.sol";
import { SepoliaConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract EncryptedRoyaltyDistribution is SepoliaConfig {
    struct EncryptedSale {
        uint256 saleId;
        euint32 encryptedAmount;
        euint32 encryptedContentId;
        uint256 timestamp;
    }

    struct DecryptedRoyalty {
        string contentId;
        uint32 amount;
        bool isReleased;
    }

    uint256 public saleCount;
    mapping(uint256 => EncryptedSale) public encryptedSales;
    mapping(uint256 => DecryptedRoyalty) public decryptedRoyalties;

    mapping(string => euint32) private encryptedContentTotals;
    string[] private contentList;

    mapping(uint256 => uint256) private requestToSaleId;

    event SaleRecorded(uint256 indexed saleId, uint256 timestamp);
    event DecryptionRequested(uint256 indexed saleId);
    event RoyaltyDecrypted(uint256 indexed saleId);

    modifier onlyReporter(uint256 saleId) {
        _;
    }

    /// @notice Record a new encrypted sale
    function recordEncryptedSale(
        euint32 encryptedAmount,
        euint32 encryptedContentId
    ) public {
        saleCount += 1;
        uint256 newId = saleCount;

        encryptedSales[newId] = EncryptedSale({
            saleId: newId,
            encryptedAmount: encryptedAmount,
            encryptedContentId: encryptedContentId,
            timestamp: block.timestamp
        });

        decryptedRoyalties[newId] = DecryptedRoyalty({
            contentId: "",
            amount: 0,
            isReleased: false
        });

        emit SaleRecorded(newId, block.timestamp);
    }

    /// @notice Request decryption of a sale
    function requestSaleDecryption(uint256 saleId) public onlyReporter(saleId) {
        EncryptedSale storage sale = encryptedSales[saleId];
        require(!decryptedRoyalties[saleId].isReleased, "Already decrypted");

        bytes32 ;
        ciphertexts[0] = FHE.toBytes32(sale.encryptedAmount);
        ciphertexts[1] = FHE.toBytes32(sale.encryptedContentId);

        uint256 reqId = FHE.requestDecryption(ciphertexts, this.decryptSale.selector);
        requestToSaleId[reqId] = saleId;

        emit DecryptionRequested(saleId);
    }

    /// @notice Callback for decrypted sale
    function decryptSale(
        uint256 requestId,
        bytes memory cleartexts,
        bytes memory proof
    ) public {
        uint256 saleId = requestToSaleId[requestId];
        require(saleId != 0, "Invalid request");

        EncryptedSale storage eSale = encryptedSales[saleId];
        DecryptedRoyalty storage dRoyalty = decryptedRoyalties[saleId];
        require(!dRoyalty.isReleased, "Already released");

        FHE.checkSignatures(requestId, cleartexts, proof);

        string[] memory results = abi.decode(cleartexts, (string[]));

        dRoyalty.contentId = results[0];
        dRoyalty.amount = parseUint(results[1]);
        dRoyalty.isReleased = true;

        if (FHE.isInitialized(encryptedContentTotals[dRoyalty.contentId]) == false) {
            encryptedContentTotals[dRoyalty.contentId] = FHE.asEuint32(0);
            contentList.push(dRoyalty.contentId);
        }
        encryptedContentTotals[dRoyalty.contentId] = FHE.add(
            encryptedContentTotals[dRoyalty.contentId],
            FHE.asEuint32(dRoyalty.amount)
        );

        emit RoyaltyDecrypted(saleId);
    }

    /// @notice Get decrypted royalty details
    function getDecryptedRoyalty(uint256 saleId) public view returns (
        string memory contentId,
        uint32 amount,
        bool isReleased
    ) {
        DecryptedRoyalty storage r = decryptedRoyalties[saleId];
        return (r.contentId, r.amount, r.isReleased);
    }

    /// @notice Get encrypted content total
    function getEncryptedContentTotal(string memory contentId) public view returns (euint32) {
        return encryptedContentTotals[contentId];
    }

    /// @notice Request decryption of content total
    function requestContentTotalDecryption(string memory contentId) public {
        euint32 total = encryptedContentTotals[contentId];
        require(FHE.isInitialized(total), "Content not found");

        bytes32 ;
        ciphertexts[0] = FHE.toBytes32(total);

        uint256 reqId = FHE.requestDecryption(ciphertexts, this.decryptContentTotal.selector);
        requestToSaleId[reqId] = bytes32ToUint(keccak256(abi.encodePacked(contentId)));
    }

    /// @notice Callback for decrypted content total
    function decryptContentTotal(
        uint256 requestId,
        bytes memory cleartexts,
        bytes memory proof
    ) public {
        uint256 contentHash = requestToSaleId[requestId];
        string memory contentId = getContentFromHash(contentHash);

        FHE.checkSignatures(requestId, cleartexts, proof);

        uint32 total = abi.decode(cleartexts, (uint32));
    }

    function bytes32ToUint(bytes32 b) private pure returns (uint256) {
        return uint256(b);
    }

    function getContentFromHash(uint256 hash) private view returns (string memory) {
        for (uint i = 0; i < contentList.length; i++) {
            if (bytes32ToUint(keccak256(abi.encodePacked(contentList[i]))) == hash) {
                return contentList[i];
            }
        }
        revert("Content not found");
    }

    function parseUint(string memory s) internal pure returns (uint32 result) {
        bytes memory b = bytes(s);
        for (uint i = 0; i < b.length; i++) {
            require(b[i] >= 0x30 && b[i] <= 0x39, "Invalid number");
            result = result * 10 + (uint32(uint8(b[i])) - 48);
        }
    }
}
