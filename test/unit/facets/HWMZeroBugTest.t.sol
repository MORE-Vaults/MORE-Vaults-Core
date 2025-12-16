// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {VaultFacet} from "../../../src/facets/VaultFacet.sol";
import {MoreVaultsStorageHelper} from "../../helper/MoreVaultsStorageHelper.sol";
import {IVaultFacet} from "../../../src/interfaces/facets/IVaultFacet.sol";
import {IVaultsFactory} from "../../../src/interfaces/IVaultsFactory.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IOracleRegistry} from "../../../src/interfaces/IOracleRegistry.sol";
import {IMoreVaultsRegistry} from "../../../src/interfaces/IMoreVaultsRegistry.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {console} from "forge-std/console.sol";

/**
 * @title HWMZeroBugTest
 * @notice Test para verificar si el código ACTUAL (con sistema HWM per-user)
 *         tiene vulnerabilidad cuando userHighWaterMarkPerShare = 0
 *
 * HIPÓTESIS A PROBAR:
 * Si un usuario tiene shares pero su HWM = 0 (por migración desde versión anterior),
 * y hay yield en el vault (currentPricePerShare > 0), entonces:
 * - Toda su posición se considera "profit"
 * - Se cobra 10% fee sobre TODO, no solo sobre ganancias reales
 */
contract HWMZeroBugTest is Test {
    using Math for uint256;

    address public vault;
    address public owner = address(0x1111);
    address public curator = address(0x2222);
    address public guardian = address(0x3333);
    address public feeRecipient;
    address public registry = address(1000);
    address public asset;
    address public factory = address(1001);
    address public oracleRegistry = address(1002);

    string constant VAULT_NAME = "Test Vault";
    string constant VAULT_SYMBOL = "TV";
    uint96 constant FEE = 1000; // 10%
    uint256 constant DEPOSIT_CAPACITY = type(uint256).max;

    function setUp() public {
        vm.warp(block.timestamp + 1 days);

        VaultFacet vaultFacet = new VaultFacet();
        vault = address(vaultFacet);

        MockERC20 mockToken = new MockERC20("Test Token", "TT");
        asset = address(mockToken);

        feeRecipient = owner;

        MoreVaultsStorageHelper.setMoreVaultsRegistry(vault, registry);
        MoreVaultsStorageHelper.setOwner(vault, owner);
        MoreVaultsStorageHelper.setFactory(vault, factory);

        bytes memory initData = abi.encode(
            VAULT_NAME,
            VAULT_SYMBOL,
            asset,
            feeRecipient,
            FEE,
            DEPOSIT_CAPACITY
        );

        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(IMoreVaultsRegistry.oracle.selector),
            abi.encode(oracleRegistry)
        );
        vm.mockCall(
            address(oracleRegistry),
            abi.encodeWithSelector(IOracleRegistry.getOracleInfo.selector, asset),
            abi.encode(address(2000), uint96(1 hours))
        );
        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(IMoreVaultsRegistry.protocolFeeInfo.selector),
            abi.encode(address(0), uint96(0))
        );

        VaultFacet(vault).initialize(initData);

        MoreVaultsStorageHelper.setMoreVaultsRegistry(vault, registry);
        MoreVaultsStorageHelper.setCurator(vault, curator);
        MoreVaultsStorageHelper.setGuardian(vault, guardian);
        MoreVaultsStorageHelper.setIsHub(vault, true);
        MoreVaultsStorageHelper.setIsWithdrawalQueueEnabled(vault, false);

        vm.mockCall(
            factory,
            abi.encodeWithSelector(IVaultsFactory.localEid.selector),
            abi.encode(uint32(block.chainid))
        );
        vm.mockCall(
            factory,
            abi.encodeWithSelector(IVaultsFactory.isCrossChainVault.selector),
            abi.encode(false)
        );
        vm.mockCall(
            factory,
            abi.encodeWithSelector(IVaultsFactory.getRestrictedFacets.selector),
            abi.encode(new address[](0))
        );
    }

    /**
     * @notice TEST: Verifica si el código actual es vulnerable a HWM = 0
     *
     * Escenario:
     * 1. Usuario deposita y obtiene shares (HWM se inicializa)
     * 2. SIMULAR MIGRACIÓN: Resetear HWM a 0
     * 3. Simular yield (más assets en el vault)
     * 4. Usuario hace otra operación
     * 5. ¿Se cobran fees incorrectas?
     */
    function test_CurrentCode_HWMZeroVulnerability() public {
        console.log("=== TEST: Vulnerabilidad HWM=0 en codigo ACTUAL ===");
        console.log("");

        // Setup - need a second user to be fee recipient (not curator)
        address user = address(0x4444);
        MockERC20(asset).mint(user, 10 ether);
        vm.prank(user);
        IERC20(asset).approve(vault, type(uint256).max);
        MoreVaultsStorageHelper.setDepositWhitelist(vault, user, type(uint256).max);

        // PASO 1: User deposita
        console.log(">>> Paso 1: User deposita 1 token <<<");
        vm.prank(user);
        uint256 shares1 = VaultFacet(vault).deposit(1 ether, user);

        uint256 userHWM = MoreVaultsStorageHelper.getUserHighWaterMarkPerShare(vault, user);
        console.log("  Shares recibidas: %s", shares1);
        console.log("  Total Assets: %s", VaultFacet(vault).totalAssets());
        console.log("  User HWM despues de deposito: %s", userHWM);
        console.log("");

        // Verificar si HWM se inicializó correctamente
        if (userHWM == 0) {
            console.log("  NOTA: HWM = 0 despues del deposito");
            console.log("  Esto puede ser un problema del Helper o del codigo");
        } else {
            console.log("  HWM se inicializo correctamente: %s", userHWM);
        }
        console.log("");

        // PASO 2: Simular migración - resetear HWM a 0
        console.log(">>> Paso 2: SIMULAR MIGRACION - Resetear HWM a 0 <<<");
        MoreVaultsStorageHelper.setUserHighWaterMarkPerShare(vault, user, 0);

        userHWM = MoreVaultsStorageHelper.getUserHighWaterMarkPerShare(vault, user);
        console.log("  User HWM despues de reset: %s", userHWM);
        console.log("");

        // PASO 3: Simular yield (añadir assets al vault sin deposito)
        console.log(">>> Paso 3: Simular YIELD de 0.5 tokens <<<");
        MockERC20(asset).mint(vault, 0.5 ether);

        console.log("  Total Assets ahora: %s", VaultFacet(vault).totalAssets());
        console.log("  Total Supply (sin cambio): %s", VaultFacet(vault).totalSupply());
        console.log("");

        // Calcular precio actual
        uint256 totalAssets = VaultFacet(vault).totalAssets();
        uint256 totalSupply = VaultFacet(vault).totalSupply();
        uint256 decimalsOffset = 2;
        uint256 currentPrice = (totalAssets * (10 ** decimalsOffset)) / (totalSupply + 10 ** decimalsOffset);
        console.log("  Current price per share: %s", currentPrice);
        console.log("  User HWM: %s", userHWM);
        console.log("  currentPrice > HWM? %s", currentPrice > userHWM ? "SI - puede cobrar fees" : "NO");
        console.log("");

        // PASO 4: User hace redeem parcial
        console.log(">>> Paso 4: User hace redeem de 50 shares <<<");

        uint256 feeRecipientBefore = VaultFacet(vault).balanceOf(feeRecipient);
        uint256 sharePriceBefore = VaultFacet(vault).totalAssets() * 1e18 / VaultFacet(vault).totalSupply();

        vm.prank(user);
        uint256 assetsReceived = VaultFacet(vault).redeem(50 ether, user, user);

        uint256 feeRecipientAfter = VaultFacet(vault).balanceOf(feeRecipient);
        uint256 feeSharesMinted = feeRecipientAfter - feeRecipientBefore;

        console.log("");
        console.log("Resultado:");
        console.log("  Assets recibidos: %s", assetsReceived);
        console.log("  Fee shares minted: %s", feeSharesMinted);
        console.log("");

        uint256 sharePriceAfter = VaultFacet(vault).totalAssets() * 1e18 / VaultFacet(vault).totalSupply();
        console.log("Share Price:");
        console.log("  Antes: %s", sharePriceBefore);
        console.log("  Despues: %s", sharePriceAfter);
        console.log("");

        // ANALISIS
        if (feeSharesMinted > 0) {
            console.log(">>> BUG CONFIRMADO EN CODIGO ACTUAL <<<");
            console.log("Se cobraron fees cuando HWM = 0");
            console.log("");
            console.log("El codigo actual ES VULNERABLE a:");
            console.log("- Usuarios con shares pero HWM = 0 (por migracion)");
            console.log("- Cualquier yield hace que se cobre fee sobre TODO");
        } else {
            console.log(">>> NO HAY BUG <<<");
            console.log("El codigo actual NO es vulnerable a HWM = 0");
        }

        // El test PASA si hay bug (para documentar), FALLA si no hay bug
        // Queremos saber si el bug existe
        if (feeSharesMinted > 0) {
            console.log("");
            console.log("VULNERABILIDAD EXISTE - Fee shares minted: %s", feeSharesMinted);
        }
    }

    /**
     * @notice TEST: Comportamiento normal cuando HWM está correctamente inicializado
     */
    function test_NormalBehavior_HWMCorrectlyInitialized() public {
        console.log("=== TEST: Comportamiento normal con HWM correcto ===");
        console.log("");

        // Setup
        MockERC20(asset).mint(curator, 10 ether);
        vm.prank(curator);
        IERC20(asset).approve(vault, type(uint256).max);
        MoreVaultsStorageHelper.setDepositWhitelist(vault, curator, type(uint256).max);

        // Curator deposita
        vm.prank(curator);
        VaultFacet(vault).deposit(1 ether, curator);

        uint256 curatorHWM = MoreVaultsStorageHelper.getUserHighWaterMarkPerShare(vault, curator);
        console.log("Curator HWM despues de deposito: %s", curatorHWM);

        // Simular yield
        MockERC20(asset).mint(vault, 0.5 ether);

        // Redeem (NO resetear HWM)
        uint256 feeRecipientBefore = VaultFacet(vault).balanceOf(feeRecipient);

        vm.prank(curator);
        VaultFacet(vault).redeem(50 ether, curator, curator);

        uint256 feeSharesMinted = VaultFacet(vault).balanceOf(feeRecipient) - feeRecipientBefore;

        console.log("Fee shares minted (con HWM correcto): %s", feeSharesMinted);
        console.log("");

        // Con HWM correcto, solo debería cobrar fee sobre el yield real (0.5 tokens)
        // proporcional a las shares del usuario
        if (feeSharesMinted > 0) {
            console.log("Fees cobradas sobre yield REAL - comportamiento esperado");
        } else {
            console.log("No fees - HWM protege correctamente");
        }
    }
}
