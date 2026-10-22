methods {
    function routingMode() external returns (Forwarder.RoutingMode) envfree;
    function upperFeeModel() external returns (Forwarder.FeeModel) envfree;
    function routingModeRaw() external returns (uint8) envfree;
    function upperFeeModelRaw() external returns (uint8) envfree;
    function lowerFeeModelRaw() external returns (uint8) envfree;
    function calculateFee(uint256) external returns (uint256) envfree;
    function paused() external returns (bool) envfree;
    function threshold() external returns (uint256) envfree;
    function variableFee() external returns (uint256) envfree;
}

rule diagUpperPercentReachable() {
    require upperFeeModel() == Forwarder.FeeModel.PERCENT;
    satisfy true;
}

rule diagUpperPercentCalculates(uint256 amount) {
    require !paused();
    require amount > threshold();
    require upperFeeModel() == Forwarder.FeeModel.PERCENT;
    calculateFee@withrevert(amount);
    satisfy !lastReverted;
}

rule diagUpperRawPercentCalculates(uint256 amount) {
    require !paused();
    require amount > threshold();
    require upperFeeModelRaw() == 2;
    calculateFee@withrevert(amount);
    satisfy !lastReverted;
}

rule diagSetLowerKeepsRouting(env e, Forwarder.FeeModel m) {
    Forwarder.RoutingMode before = routingMode();
    setLowerFeeModel(e, m);
    assert routingMode() == before;
}

rule diagSetLowerKeepsRoutingWhenValid(env e, Forwarder.FeeModel m) {
    require routingModeRaw() < 4 && lowerFeeModelRaw() < 4 && upperFeeModelRaw() < 4;
    Forwarder.RoutingMode before = routingMode();
    setLowerFeeModel(e, m);
    assert routingMode() == before;
}

rule diagSetLowerKeepsRawRouting(env e, Forwarder.FeeModel m) {
    uint8 before = routingModeRaw();
    setLowerFeeModel(e, m);
    assert routingModeRaw() == before;
}
