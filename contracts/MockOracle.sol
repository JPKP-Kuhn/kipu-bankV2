// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

contract MockOracle {
    int256 private price;
    uint8 private decs;
    uint256 private updatedAt;

    constructor(int256 _price, uint8 _decimals) {
        price = _price;
        decs = _decimals;
        updatedAt = block.timestamp;
    }

    function latestAnswer() external view returns (int256) {
        return price;  // Ex.: 200000000000 para ETH/USD ~$2000 com 8 decimais
    }

    function decimals() external view returns (uint8) {
        return decs;  // Tipicamente 8 para Chainlink
    }
    
    function latestRoundData() external view returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAtTimestamp,
        uint80 answeredInRound
    ) {
        return (1, price, block.timestamp, updatedAt, 1);
    }

    // Função para atualizar preço (para testes dinâmicos)
    function setPrice(int256 _newPrice) external {
        price = _newPrice;
        updatedAt = block.timestamp;
    }
}
