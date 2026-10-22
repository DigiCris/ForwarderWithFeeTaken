# Test matrix — Forwarder

Every requirement of the test plan, mapped to the tests that exercise it. File abbreviations:

| Abbrev. | File / contract |
|---|---|
| `U-Ctor` | `test/Forwarder.t.sol:ForwarderConstructorTest` |
| `U-Fee` | `test/Forwarder.t.sol:ForwarderFeeTest` |
| `U-AC` | `test/Forwarder.t.sol:ForwarderAccessControlTest` |
| `U-Val` | `test/Forwarder.t.sol:ForwarderValidationTest` |
| `U-Route` | `test/ForwarderRouting.t.sol:ForwarderRoutingTest` |
| `U-Fallback` | `test/ForwarderRouting.t.sol:ForwarderUserFallbackTest` |
| `U-Treasury` | `test/ForwarderRouting.t.sol:ForwarderTreasuryDeliveryTest` |
| `U-Donation` | `test/ForwarderRouting.t.sol:ForwarderAccidentalBalanceTest` |
| `U-Zero` | `test/ForwarderRouting.t.sol:ForwarderZeroValuesTest` |
| `U-Allow` | `test/ForwarderRouting.t.sol:ForwarderAllowanceTest` |
| `U-SetVault` | `test/ForwarderVaultAndRescue.t.sol:ForwarderSetVaultTest` |
| `U-Rescue` | `test/ForwarderVaultAndRescue.t.sol:ForwarderRescueTest` |
| `U-Reent` | `test/ForwarderVaultAndRescue.t.sol:ForwarderReentrancyTest` |
| `F` | `test/ForwarderFuzz.t.sol:ForwarderFuzzTest` |
| `I` | `test/ForwarderInvariant.t.sol:ForwarderInvariantTest` (handler `test/invariants/ForwarderHandler.sol`) |
| `K` | `test/fork/ForkTestBase.sol` + `test/ForwarderFork.t.sol:ForwarderForkTest` (Base mainnet fork) |
| `P` | `test/ForwarderPostDeployFork.t.sol:ForwarderPostDeployForkTest` (deployed contract on a fork) |
| `E` | `echidna/ForwarderEchidna.sol` (Echidna properties) |
| `C` | `certora/specs/Forwarder.spec` (Certora rules) |

## Fee calculation

| Case | Tests |
|---|---|
| 0%, 0.001%, 0.1%, 1%, 10% | U-Fee `test_VariableFeeGranularity`, `test_VariableFeeAtMaximumIsAccepted` |
| > 10% rejected (both setters, incl. `type(uint256).max`) | U-Fee `test_RevertWhen_VariableFeeAboveMaximum`; F `testFuzz_SetterBounds`; I `invariant_FeeConfigWithinCaps`; E `echidna_fee_caps`; C `feeCaps`, `settersRejectValuesAboveCaps` |
| fixed 0, 0.000001 USDC, 10 USDC | U-Fee `test_FixedFeeValues` |
| fixed > 10 USDC rejected | U-Fee `test_RevertWhen_FixedFeeAboveMaximum`; F `testFuzz_SetterBounds`; C `fixedFeeSetterRejectsValuesAboveCap` |
| NONE / FIXED / PERCENT / FIXED_PLUS_PERCENT | U-Fee `test_EachFeeModel` |
| amount < / == / > threshold | U-Fee `test_ThresholdBoundaries`, `test_AllModelCombinationsAroundThreshold`; C `lowerModelUpToThreshold`, `upperModelAboveThreshold` |
| all 16 lower/upper combinations | U-Fee `test_AllModelCombinationsAroundThreshold`; F `testFuzz_CalculateFeeMatchesSpecification` |
| full amount above threshold (spec example 150 USDC) | U-Fee `test_FeeUsesFullAmountAboveThreshold`, `test_FeeUsesFullAmountWhenUpperIsFixedPlusPercent`; F `testFuzz_FeeAboveThresholdUsesFullAmount`; K `test_Fork_FeeUsesFullAmountAboveThreshold`; C `percentUsesWholeAmount`, `percentUsesWholeAmountIsNotTheExcessFee` |
| paused ⇒ fee 0 | U-Fee `test_PausedFeeIsZero`; F `testFuzz_PausedFeeIsZero`; I `invariant_PausedImpliesZeroFee`; E `echidna_paused_means_zero_fee`; K `test_Fork_PausedFeesForwardFullAmount`; C `pausedFeeIsZero`, `pausedForwardDeliversWholeAmount` |
| fee == amount | U-Fee `test_FeeEqualToAmount`; U-Zero `test_ZeroUserAmountWithFallback`, `test_ZeroUserAmountWithWorkingZeroDeposit`; K `test_Fork_FeeEqualToAndAboveAmount` |
| fee just below amount | U-Fee `test_FeeJustBelowAmount` |
| fee > amount reverts (checked arithmetic, no clamp) | U-Fee `test_RevertWhen_FeeAboveAmount`, `test_RevertWhen_FixedFeeAndZeroAmount`; F `testFuzz_ForwardAccounting`; K `test_Fork_FeeEqualToAndAboveAmount` |
| rounding down | U-Fee `test_PercentRoundsDown` |
| exact formula, only overflow can revert | C `feeMatchesSpecification`; F `testFuzz_CalculateFeeNeverRevertsForRealisticAmounts`, `testFuzz_FeeIsBoundedByCaps` |
| fee config events | U-Fee `test_IndividualSettersEmitFullConfig` |

## Roles

| Case | Tests |
|---|---|
| every admin function from fee manager / stranger reverts | U-AC `test_FeeManagerAndStrangerCannotCallAdminFunctions`; F `testFuzz_UnprivilegedCallerCannotConfigure`; I `invariant_NoUnexpectedOutcome` (handler `unauthorizedCall`); E `echidna_no_unexpected_outcome`; K `test_Fork_EveryFeeManagerCanConfigureAndPauseButNotAdminister`, `test_Fork_StrangerCannotDoAnything`; C `onlyAdminChangesTreasury`, `onlyAdminChangesVault`, `onlyAdminChangesRoutingMode`, `feeManagerCannotAdminister`, `unprivilegedChangesNothing` |
| every fee function from admin / stranger reverts | U-AC `test_AdminAndStrangerCannotCallFeeManagerFunctions`; C `onlyFeeManagerChangesFeeConfig` |
| every fee manager can set fees | U-AC `test_EveryFeeManagerCanSetFees`; K `test_Fork_EveryFeeManagerCanConfigureAndPauseButNotAdminister` (all 7 production fee managers) |
| fee manager can pause / admin can pause / stranger cannot | U-AC `test_FeeManagerCanPause`, `test_AdminCanPause`, `test_RevertWhen_StrangerPauses`; C `onlyPrivilegedPause` |
| fee manager cannot unpause / admin can | U-AC `test_FeeManagerCannotUnpause`, `test_AdminCanUnpause`; C `onlyAdminUnpauses` |
| fee manager cannot change treasury / vault / routing / rescue | U-AC `test_FeeManagerCannotChangeTreasuryVaultRoutingOrRescue`; C `feeManagerCannotAdminister` |
| fee manager cannot grant roles | U-AC `test_FeeManagerCannotGrantRoles` |
| admin manages fee managers | U-AC `test_AdminManagesFeeManagers`; K `test_Fork_AdminSafeCanAdminister` |
| default admin transfer delay (3 days), no direct grant | U-AC `test_DefaultAdminTransferRespectsDelay`, `test_DefaultAdminCannotBeGrantedDirectly` |
| compromised fee manager blast radius | U-AC `test_CompromisedFeeManagerBlastRadius` |
| privileges never change under random sequences | I `invariant_PrivilegesNeverChange`; E `echidna_roles_never_change` |

## Routing

| Case | Tests |
|---|---|
| DIRECT_DIRECT | U-Route `test_DirectDirect`; K `test_Fork_AllRoutingModes` |
| VAULT_USER_DIRECT_TREASURY | U-Route `test_VaultUserDirectTreasury`; K `test_Fork_AllRoutingModes` |
| DIRECT_USER_VAULT_TREASURY | U-Route `test_DirectUserVaultTreasury`; K `test_Fork_AllRoutingModes` |
| VAULT_VAULT | U-Route `test_VaultVault`; K `test_Fork_AllRoutingModes` |
| balances/shares of user, treasury and Forwarder | all of the above; F `testFuzz_ForwardAccounting`; I `invariant_UserGetsExactlyAmountMinusFee`, `invariant_TreasuryAccounting`, `invariant_Conservation`; C `forwardUserReceivesAmountMinusFee`, `forwardTreasuryAccounting` |
| mode changes between forwards | U-Route `test_SequentialForwardsAcrossModeChanges` |
| third-party real vault | K `test_Fork_ReplaceVaultWithThirdPartyVault` (Steakhouse USDC) |

## Vault failure — user (fallback to USDC)

| Case | Tests |
|---|---|
| deposit reverts | U-Fallback `test_FallbackWhenDepositReverts` |
| allowance exhausted | U-Fallback `test_FallbackWhenAllowanceIsExhausted`; K `test_Fork_UserFallbackWhenAllowanceIsExhausted` (real USDC) |
| vault state (paused, cap) | U-Fallback `test_FallbackWhenVaultIsPaused`, `test_FallbackWhenDepositCapIsExceededWhileTreasuryDepositWorks`; K `test_Fork_UserFallbackWhenVaultDepositsArePaused` (real guardian pause), `test_Fork_UserFallbackAboveVaultCapacity` (real Aave capacity) |
| fallback event | all of the above (`UserVaultDepositFailed` asserted with the revert reason) |
| fallback transfer also fails ⇒ revert | U-Fallback `test_RevertWhen_FallbackTransferAlsoFails`, `test_RevertWhen_DirectUserTransferFails`; K `test_Fork_RevertWhen_UserIsBlacklisted` |
| recovery after failure | U-Fallback `test_VaultDepositResumesAfterRecovery` |
| malformed vault return (documented trust limit) | U-Fallback `test_UserLegRevertsWhenVaultReturnsMalformedData` |

## Vault / direct failure — treasury (best effort)

| Case | Tests |
|---|---|
| treasury vault deposit fails, user unaffected, funds kept, retried | U-Treasury `test_TreasuryVaultFailureKeepsFundsAndRetries`, `test_TreasuryOnlyVaultFailureInVaultVault`; K `test_Fork_TreasuryVaultFailureIsRetried` |
| malformed vault return never reverts the user delivery | U-Treasury `test_TreasuryLegNeverRevertsOnMalformedVaultReturn` |
| direct transfer returns false | U-Treasury `test_DirectTreasuryTransferReturningFalse` |
| direct transfer reverts (blacklist) | U-Treasury `test_DirectTreasuryTransferReverting`; K `test_Fork_TreasuryDirectFailureIsRetried` (real USDC blacklist) |
| accumulation and retry | U-Treasury `test_FailuresAccumulateAndAreDeliveredTogether` |
| pending funds after treasury replacement | U-Treasury `test_PendingFundsGoToTheNewTreasury` |
| no treasury action when balance is zero | U-Treasury `test_NoTreasuryActionWhenNothingIsLeft` |
| never reverts forward (formal) | C `treasuryFailureNeverRevertsForward` |

## Accidental USDC

| Case | Tests |
|---|---|
| donation swept with the fee (direct / vault / without fees) | U-Donation `test_DonationIsSweptDirectly`, `test_DonationIsDepositedForTreasury`, `test_DonationIsSweptEvenWithoutFees`; K `test_Fork_AccidentalUsdcIsSwept` |
| user never receives the donation | U-Donation `test_UserNeverReceivesTheDonation` |

## Rescue

| Case | Tests |
|---|---|
| USDC | U-Rescue `test_RescueUsdc`, `test_RescueUsdcInVaultModeGoesDirectlyToTreasury`; K `test_Fork_RescueRealTokensAndNative` |
| USDT-like (no return value) | U-Rescue `test_RescueUsdtLikeToken`; K (real bridged USDT on Base) |
| DAI-like | U-Rescue `test_RescueDaiLikeToken`; K (real DAI on Base) |
| arbitrary token / vault shares / zero balance | U-Rescue `test_RescueArbitraryToken`, `test_RescueVaultShares`, `test_RescueZeroBalance`; K (USDbC, WETH) |
| native (balance set / forced via SELFDESTRUCT / zero) | U-Rescue `test_RescueNative`, `test_RescueForcedNative`, `test_RescueNativeZeroBalance`; K `test_Fork_RescueRealTokensAndNative` (real treasury Safe) |
| only admin, 100% to current treasury | U-AC `test_FeeManagerAndStrangerCannotCallAdminFunctions`; U-Rescue `test_RescueGoesToCurrentTreasury`; F `testFuzz_RescueSendsEverythingToTreasury`; C `rescueTokenOnlyToTreasury`, `rescueNativeOnlyToTreasury` |
| failure modes | U-Rescue `test_RevertWhen_RescueTokenReturnsFalse`, `test_RevertWhen_TreasuryRejectsNative` |

## Vault health check (`setVault` and constructor)

| Case | Tests |
|---|---|
| address(0) | U-SetVault `test_RevertWhen_VaultIsZero` |
| EOA | U-SetVault `test_RevertWhen_VaultIsEoa`; K `test_Fork_RejectInvalidVaults` |
| non ERC-4626 contract | U-SetVault `test_RevertWhen_VaultIsNotErc4626`; K `test_Fork_RejectInvalidVaults` (USDC) |
| wrong asset | U-SetVault `test_RevertWhen_VaultAssetIsNotUsdc`; U-Ctor `test_RevertWhen_DeployWithWrongAssetVault`; K `test_Fork_RejectInvalidVaults` (Moonwell Flagship ETH) |
| deposit fails / vault paused | U-SetVault `test_RevertWhen_VaultDepositFails`, `test_RevertWhen_VaultIsPaused` |
| no shares minted | U-SetVault `test_RevertWhen_VaultMintsNoShares` |
| redeem fails | U-SetVault `test_RevertWhen_VaultRedeemFails`; U-Ctor `test_RevertWhen_DeployWithFailingVault` |
| redeem returns 0 | U-SetVault `test_RevertWhen_VaultRedeemReturnsNothing` |
| valid vault with rounding | U-SetVault `test_VaultWithRoundingLossIsAccepted`; K `test_Fork_HealthCheckOnLucaVaultAcceptsRounding` (999 of 1000) |
| valid vault returning less than deposited (> 0) | U-SetVault `test_VaultReturningLessThanDepositedIsAccepted`; F `testFuzz_HealthCheckAcceptsAnyPositiveReturn` |
| caller funds only; Forwarder funds untouched | U-SetVault `test_HealthCheckNeverUsesForwarderFunds`, `test_HealthCheckRefundsAssetsTheVaultDidNotPull`, `test_HealthCheckOnlyRedeemsNewShares`, `test_RevertWhen_CallerDidNotFundHealthCheck`; C `healthCheckUsesOnlyCallerFunds` |
| atomicity (no partial state) | U-SetVault `test_FailedHealthCheckLeavesNoPartialState`; U-Allow `test_FailedReplacementKeepsAllowances` |
| deployment health check | U-Ctor `test_DeploymentHealthCheckUsesAndRefundsDeployerFunds`, `test_RevertWhen_DeployHealthCheckNotFunded`; K `test_Fork_DeploymentState` |

## Allowances

| Case | Tests |
|---|---|
| all 16 routing transitions (value + whether `approve` was called) | U-Allow `test_EveryRoutingTransition`; K `test_Fork_AllowanceTransitionsWithRealUsdc`; C `routingModeAllowance` |
| DIRECT_DIRECT ⇒ 0 | I `invariant_Allowances`; E `echidna_allowances`; C `directDirectMeansNoVaultAllowance` |
| vault replacement: old 0, new MAX/0 | U-Allow `test_VaultReplacementInVaultMode`, `test_VaultReplacementInDirectMode`; K `test_Fork_ReplaceVaultWithThirdPartyVault`; C `setVaultAllowances` |
| forward never approves | U-Allow `test_ForwardNeverApproves`; C `forwardNeverApproves` |
| USDC decrements MAX; refresh by re-setting the vault | U-Allow `test_UsdcStyleAllowanceDecrementAndRefresh`; K `test_Fork_AllowanceTransitionsWithRealUsdc` |
| random sequences | F `testFuzz_RoutingSequenceAllowance`; I `invariant_Allowances` (exact model incl. decrements) |

## Zero values

| Case | Tests |
|---|---|
| amount 0 | U-Zero `test_ZeroAmountDirect`; K `test_Fork_ZeroAmount` |
| fee 0 | U-Zero `test_ZeroFee` |
| userAmount 0 | U-Zero `test_ZeroUserAmountWithFallback`, `test_ZeroUserAmountWithWorkingZeroDeposit` |
| deposit(0) works | U-Zero `test_ZeroAmountVaultDepositThatWorks` |
| deposit(0) reverts ⇒ fallback | U-Zero `test_ZeroAmountVaultDepositThatRevertsFallsBack`; K `test_Fork_ZeroAmount` (real Luca vault reverts on 0 and falls back) |

## Reentrancy

| Case | Tests |
|---|---|
| vault reenters `forward` | U-Reent `test_ForwardCannotBeReentered` |
| vault reenters privileged functions (as admin) | U-Reent `test_SetRoutingModeCannotBeReenteredFromForward`, `test_SetVaultCannotBeReenteredFromForward`, `test_RescueTokenCannotBeReenteredFromForward`, `test_RescueNativeCannotBeReenteredFromForward` |
| candidate vault reenters during health check | U-Reent `test_CandidateVaultCannotReenterForwardDuringHealthCheck`, `test_CandidateVaultCannotReenterSetVaultDuringHealthCheck` |
| rescued token reenters | U-Reent `test_RescuedTokenCannotReenter` |
| configuration snapshot | U-Reent `test_ForwardUsesConfigurationSnapshot` |

## State transitions, validation and structure

| Case | Tests |
|---|---|
| random sequences of fees, pause, routing, vault, unpause, rescue, forward, treasury/vault replacement, failures | I (13 handler actions, 12 invariants); E (13 actions, 11 properties) |
| token must be USDC | U-Val `test_RevertWhen_TokenIsNotUsdc`; F `testFuzz_RevertWhen_TokenIsNotUsdc`; C `forwardOnlyAcceptsUsdc` |
| recipient validation | U-Val `test_RevertWhen_RecipientIsZero`, `test_RevertWhen_RecipientIsForwarder`; F `testFuzz_AnyValidRecipient` |
| pull failures | U-Val `test_RevertWhen_CallerHasNoAllowance`, `test_RevertWhen_CallerHasNoBalance`, `test_RevertWhen_UsdcIsPaused` |
| forward never paused | U-Val `test_ForwardWorksWhilePaused`; K `test_Fork_PausedFeesForwardFullAmount` |
| treasury validation | U-Val `test_SetTreasury`, `test_RevertWhen_TreasuryIsZeroOrForwarder`; I `invariant_TreasuryIsAlwaysValid`; C `treasuryIsValid` |
| vault mode requires a vault | U-Val `test_RevertWhen_VaultModeWithoutVault`; U-Ctor `test_RevertWhen_DeployVaultModeWithoutVault`; I `invariant_VaultModeHasVault`; C `vaultModeHasVault` |
| constructor validation and initial state | U-Ctor (18 tests); K `test_Fork_DeploymentState`, `test_Fork_ProductionConfiguration`, `test_Fork_DeployerOutsideTheListIsAddedAsFeeManager`, `test_Fork_RevertWhen_DeployerHasNoUsdc` |
| no DELEGATECALL / CALLCODE / SELFDESTRUCT, code never changes | U-Ctor `test_RuntimeCodeHasNoDelegatecallOrSelfdestruct`; I `invariant_CodeNeverChanges` |
| no native receive | U-Ctor `test_RejectsDirectNativeTransfers`; K `test_Fork_RejectsDirectNative` |
| bytecode of the deployed contract equals the audited source | K `test_Fork_SameBytecodeAsLocalArtifact`; P `test_PostDeploy_RuntimeCodeMatchesAuditedSource` |
