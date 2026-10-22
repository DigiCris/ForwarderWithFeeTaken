methods {
    function upperFeeModel() external returns (Forwarder.FeeModel) envfree;
    function upperFeeModelRaw() external returns (uint8) envfree;
    function threshold() external returns (uint256) envfree;
    function fixedFee() external returns (uint256) envfree;
    function variableFee() external returns (uint256) envfree;
    function calculateFee(uint256) external returns (uint256) envfree;
    function paused() external returns (bool) envfree;
}

rule concreteReachableBaseline() {
    require !paused();
    require variableFee() == 1000;
    assert variableFee() == 1000;
}

rule concretePercentFeeRaw() {
    require upperFeeModelRaw() == 2;
    require threshold() == 0 && variableFee() == 1000 && !paused();
    assert calculateFee(1000000) == 10000;
}

rule concretePercentFeeEnum() {
    require upperFeeModel() == Forwarder.FeeModel.PERCENT;
    require threshold() == 0 && variableFee() == 1000 && !paused();
    assert calculateFee(1000000) == 10000;
}

rule concreteFixedFeeEnum() {
    require upperFeeModel() == Forwarder.FeeModel.FIXED;
    require threshold() == 0 && fixedFee() == 7 && !paused();
    assert calculateFee(1000000) == 7;
}

rule concreteNoneFeeEnum() {
    require upperFeeModel() == Forwarder.FeeModel.NONE;
    require threshold() == 0 && !paused();
    assert calculateFee(1000000) == 0;
}
