// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

contract MockOracle {
    int256 private price;
    uint8 private decs;

    constructor(int256 _price, uint8 _decimals) {
        price = _price;
        decs = _decimals;
    }

    function latestAnswer() external view returns (int256) {
        return price;  // Ex.: 200000000000 para ETH/USD ~$2000 com 8 decimais
    }

    function decimals() external view returns (uint8) {
        return decs;  // Tipicamente 8 para Chainlink
    }

    // Função para atualizar preço (para testes dinâmicos)
    function setPrice(int256 _newPrice) external {
        price = _newPrice;
    }
}
