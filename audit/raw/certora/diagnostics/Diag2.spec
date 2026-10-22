methods {
    function routingMode() external returns (Forwarder.RoutingMode) envfree;
    function upperFeeModel() external returns (Forwarder.FeeModel) envfree;
    function upperFeeModelRaw() external returns (uint8) envfree;
    function threshold() external returns (uint256) envfree;
    function calculateFee(uint256) external returns (uint256) envfree;
    function paused() external returns (bool) envfree;
}

rule ctlSatisfyTrue() {
    satisfy true;
}

rule ctlThresholdFive() {
    satisfy threshold() == 5;
}

rule ctlUpperFixed() {
    satisfy upperFeeModel() == Forwarder.FeeModel.FIXED;
}

rule ctlUpperPercent() {
    satisfy upperFeeModel() == Forwarder.FeeModel.PERCENT;
}

rule ctlUpperRawTwo() {
    satisfy upperFeeModelRaw() == 2;
}

rule ctlPercentFeePositive(uint256 amount) {
    require !paused() && amount > threshold() && upperFeeModel() == Forwarder.FeeModel.PERCENT;
    satisfy calculateFee(amount) > 0;
}

rule ctlPercentFeeAssert(uint256 amount) {
    require !paused() && amount > threshold() && upperFeeModel() == Forwarder.FeeModel.PERCENT;
    uint256 fee = calculateFee(amount);
    assert fee <= amount;
}
