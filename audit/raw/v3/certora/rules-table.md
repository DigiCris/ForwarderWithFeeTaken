| Rule / invariant | Job (final) | Final | Non-vacuity witnesses | History |
|---|---|---|---|---|
| `activeOverrideIsNeverWorsened` | run2 | **PASS** | 24 | run1: PASS; run2: PASS |
| `adminWithoutFeeRoleCannotChangeFees` | run2 | **PASS** | 24 | run1: PASS; run2: PASS |
| `authorizedCanAlwaysCancelFeeConfig` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `cancelClearsPendingOnly` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `cancelFeeConfigClearsPendingOnly` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `cancelTreasuryClearsPendingOnly` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `directDirectMeansNoVaultAllowance` | run2 | **PASS** | 52 | run1: PASS; run2: PASS |
| `discountedFeeIsReachable` | run2 | **PASS** | — (satisfy rule: the witness is the result) | run1: PASS; run2: PASS |
| `effectiveFeeFollowsLaterGlobalChanges` | run3 | **TIMEOUT** | — | run1: TIMEOUT; run2: TIMEOUT; run3: TIMEOUT |
| `effectiveFeeFollowsLaterGlobalChangesAssisted` | run3 | **UNKNOWN** | — | run3: UNKNOWN |
| `effectiveFeeMatchesSpecification` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `effectiveFeeMatchesSpecificationForAnyConfiguration` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `effectiveFeeNeverExceedsGlobalFee` | run3 | **TIMEOUT** | — | run1: TIMEOUT; run2: TIMEOUT; run3: TIMEOUT |
| `effectiveFeeNeverExceedsGlobalFeeAssisted` | run5 | **PASS** | 1 | run3: PASS; run5: PASS |
| `effectiveSpecFeeNeverExceedsGlobalSpecFee` | run5 | **PASS** | 1 | run3: PASS; run4: PASS; run5: PASS |
| `enumsAreValid` | run2 | **PASS** | 52 | run1: PASS; run2: PASS |
| `executeActivatesPendingVaultAndClearsIt` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `executeAllowancesFollowCurrentRouting` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `executeFeeConfigAppliesPendingAndClearsIt` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `executeFeeConfigRevertsBeforeExecutableAt` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `executeFeeConfigRevertsWithoutPendingChange` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `executeFeeConfigStoresProposedConfiguration` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `executeHealthCheckUsesOnlyCallerFunds` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `executeRevertsBeforeExecutableAt` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `executeRevertsWithoutPendingChange` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `executeTreasuryActivatesPendingAndClearsIt` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `executeTreasuryRevertsBeforeExecutableAt` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `executeTreasuryRevertsWithoutPendingChange` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `executeUsesRoutingInForceAtExecution` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `expiredOverrideIsTheGlobalFee` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `failedExecutionKeepsState` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `failedFeeExecutionKeepsState` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `feeCaps` | run2 | **PASS** | 52 | run1: PASS; run2: PASS |
| `feeChangeDelayIs72Hours` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `feeConfigOnlyChangesThroughMaturedExecution` | run2 | **PASS** | 24 | run1: PASS; run2: PASS |
| `feeLifecycleKeepsEverythingElse` | run2 | **PASS** | 3 | run1: PASS; run2: PASS |
| `feeManagerAdminIsDefaultAdmin` | run2 | **PASS** | 52 | run1: PASS; run2: PASS |
| `feeManagerCannotAdminister` | run2 | **PASS** | 24 | run1: PASS; run2: PASS |
| `feeManagerCannotAdministerVault` | run2 | **PASS** | 24 | run1: PASS; run2: PASS |
| `feeManagerCannotTouchTheTreasury` | run2 | **PASS** | 24 | run1: PASS; run2: PASS |
| `feeManagerRoleOnlyChangedByAdminOrSelf` | run2 | **PASS** | 24 | run1: PASS; run2: PASS |
| `feeMatchesSpecification` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `feeMatchesSpecificationForAnyConfiguration` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `fixedModelChargesAfterConfiguration` | run2 | **PASS** | — (satisfy rule: the witness is the result) | run1: PASS; run2: PASS |
| `fixedModelIsReachable` | run2 | **PASS** | — (satisfy rule: the witness is the result) | run1: PASS; run2: PASS |
| `fixedPlusPercentModelChargesAfterConfiguration` | run2 | **PASS** | — (satisfy rule: the witness is the result) | run1: PASS; run2: PASS |
| `fixedPlusPercentModelIsReachable` | run2 | **PASS** | — (satisfy rule: the witness is the result) | run1: PASS; run2: PASS |
| `forwardDoesNotChangeConfiguration` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `forwardKeepsPendingChange` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `forwardNeverApproves` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `forwardNeverPaysThePendingTreasury` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `forwardOnlyAcceptsUsdc` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `forwardTreasuryAccounting` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `forwardTreasuryAccountingForAnyConfiguration` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `forwardUserReceivesAmountMinusEffectiveFeeForAnyConfiguration` | run3 | **PASS** | 1 | run3: PASS |
| `forwardUserReceivesAmountMinusFee` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `forwardUserReceivesAmountMinusFeeForAnyConfiguration` | run3 | **TIMEOUT** | — | run1: TIMEOUT; run2: TIMEOUT; run3: TIMEOUT |
| `guardianAdminIsDefaultAdmin` | run2 | **PASS** | 52 | run1: PASS; run2: PASS |
| `guardianCanOnlyCancel` | run2 | **PASS** | 24 | run1: PASS; run2: PASS |
| `guardianCannotProposeOrExecute` | run2 | **PASS** | 2 | run1: PASS; run2: PASS |
| `guardianOrAdminCanAlwaysCancel` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `guardianOrAdminCanAlwaysCancelTreasury` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `guardianRoleChangesKeepPendingChange` | run2 | **PASS** | 3 | run1: PASS; run2: PASS |
| `guardianRoleOnlyChangedByAdminOrSelf` | run2 | **PASS** | 24 | run1: PASS; run2: PASS |
| `lowerModelUpToThreshold` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `mathMinIsTheMinimum` | run2 | **PASS** | 1 | run2: PASS |
| `mathMinReturnsTheFirstArgument` | run2 | **PASS** | — (satisfy rule: the witness is the result) | run2: PASS |
| `mathMinReturnsTheSecondArgument` | run2 | **PASS** | — (satisfy rule: the witness is the result) | run2: PASS |
| `onlyAdminChangesRoutingMode` | run2 | **PASS** | 24 | run1: PASS; run2: PASS |
| `onlyAdminChangesTreasury` | run2 | **PASS** | 24 | run1: PASS; run2: PASS |
| `onlyAdminChangesVault` | run2 | **PASS** | 24 | run1: PASS; run2: PASS |
| `onlyAdminExecutes` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `onlyAdminExecutesTreasury` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `onlyAdminOrGuardianCancels` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `onlyAdminOrGuardianCancelsTreasury` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `onlyAdminProposes` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `onlyAdminProposesTreasury` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `onlyAdminUnpauses` | run2 | **PASS** | 24 | run1: PASS; run2: PASS |
| `onlyAuthorizedCancelsFeeConfig` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `onlyFeeManagerChangesFeeConfig` | run2 | **PASS** | 24 | run1: PASS; run2: PASS |
| `onlyFeeManagerExecutesFeeConfig` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `onlyFeeManagerProposesFeeConfig` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `onlyFeeManagerSetsOverrides` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `onlyPrivilegedPause` | run2 | **PASS** | 24 | run1: PASS; run2: PASS |
| `overridesOnlyChangeThroughSetUserFeeOverride` | run2 | **PASS** | 24 | run1: PASS; run2: PASS |
| `pausedEffectiveFeeIsZero` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `pausedFeeIsZero` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `pausedForwardDeliversWholeAmount` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `pausedForwardDeliversWholeAmountForAnyConfiguration` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `pendingChangeCannotBeShortened` | run2 | **PASS** | 24 | run1: PASS; run2: PASS |
| `pendingFeeCaps` | run2 | **PASS** | 52 | run1: PASS; run2: PASS |
| `pendingFeeConfigCannotBeShortened` | run2 | **PASS** | 24 | run1: PASS; run2: PASS |
| `pendingFeeConfigOnlyClearedByCancelOrExecute` | run2 | **PASS** | 24 | run1: PASS; run2: PASS |
| `pendingFeeConsistency` | run2 | **PASS** | 52 | run1: PASS; run2: PASS |
| `pendingFeeEnumsAreValid` | run2 | **PASS** | 52 | run1: PASS; run2: PASS |
| `pendingOnlyClearedByCancelOrExecute` | run2 | **PASS** | 24 | run1: PASS; run2: PASS |
| `pendingTreasuryCannotBeShortened` | run2 | **PASS** | 24 | run1: PASS; run2: PASS |
| `pendingTreasuryConsistency` | run2 | **PASS** | 52 | run1: PASS; run2: PASS |
| `pendingTreasuryIsValid` | run2 | **PASS** | 52 | run1: PASS; run2: PASS |
| `pendingTreasuryOnlyClearedByCancelOrExecute` | run2 | **PASS** | 24 | run1: PASS; run2: PASS |
| `pendingVaultConsistency` | run2 | **PASS** | 52 | run1: PASS; run2: PASS |
| `pendingVaultHasNoAllowance` | run2 | **PASS** | 52 | run1: PASS; run2: PASS |
| `pendingVaultIsNotActive` | run2 | **PASS** | 52 | run1: PASS; run2: PASS |
| `percentAboveThresholdIsNotExcessFee` | run2 | **PASS** | — (satisfy rule: the witness is the result) | run1: PASS; run2: PASS |
| `percentAboveThresholdUsesWholeAmount` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `percentModelIsReachable` | run2 | **PASS** | — (satisfy rule: the witness is the result) | run1: PASS; run2: PASS |
| `percentPartIsMonotone` | run5 | **PASS** | 1 | run3: PASS; run4: PASS; run5: PASS |
| `percentUsesWholeAmount` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `percentUsesWholeAmountIsNotTheExcessFee` | run2 | **PASS** | — (satisfy rule: the witness is the result) | run1: PASS; run2: PASS |
| `productIsMonotone` | run5 | **FAIL** | — | run3: FAIL; run4: FAIL; run5: FAIL |
| `proposeFeeConfigEnforcesTheCaps` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `proposeFeeConfigRevertsWhileAChangeIsPending` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `proposeFeeConfigStoresExactProposal` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `proposeHealthCheckUsesOnlyCallerFunds` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `proposeLeavesNoCandidateAllowance` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `proposeRevertsWhileAChangeIsPending` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `proposeStoresCandidateWithExactDelay` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `proposeTreasuryRejectsInvalidCandidates` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `proposeTreasuryRevertsWhileAChangeIsPending` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `proposeTreasuryStoresCandidateWithExactDelay` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `rescueNativeOnlyToTreasury` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `rescueTokenOnlyToTreasury` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `rescueWhileTreasuryPendingPaysTheActiveTreasury` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `routingModeAllowance` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `setUserFeeOverrideLiveness` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `setUserFeeOverrideTouchesOnlyThatOverride` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `setUserFeeOverrideValidation` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `specFeeIsMonotone` | run5 | **PASS** | 1 | run3: PASS; run4: PASS; run5: PASS |
| `treasuryChangeDelayIs72Hours` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `treasuryFailureNeverRevertsForward` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `treasuryFailureNeverRevertsForwardForAnyConfiguration` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `treasuryIsValid` | run2 | **PASS** | 52 | run1: PASS; run2: PASS |
| `treasuryLifecycleKeepsEverythingElse` | run2 | **PASS** | 3 | run1: PASS; run2: PASS |
| `treasuryOnlyChangesThroughMaturedExecution` | run2 | **PASS** | 24 | run1: PASS; run2: PASS |
| `unprivilegedCannotTouchVaultLifecycle` | run2 | **PASS** | 24 | run1: PASS; run2: PASS |
| `unprivilegedChangesNoConfiguration` | run2 | **PASS** | 24 | run1: PASS; run2: PASS |
| `upperModelAboveThreshold` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `vaultChangeDelayIs72Hours` | run2 | **PASS** | 1 | run1: PASS; run2: PASS |
| `vaultLifecycleKeepsConfiguration` | run2 | **PASS** | 3 | run1: PASS; run2: PASS |
| `vaultModeHasVault` | run2 | **PASS** | 52 | run1: PASS; run2: PASS |
| `vaultOnlyChangesThroughExecuteAfterDelay` | run2 | **PASS** | 24 | run1: PASS; run2: PASS |
| `zeroAddressHasNoOverride` | run2 | **PASS** | 52 | run1: PASS; run2: PASS |

Totals (final): FAIL 1, PASS 137, TIMEOUT 3, UNKNOWN 1 — 142 entries
