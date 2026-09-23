#pragma once

struct PowerSplit {
    double pv   = 0.0;
    double grid = 0.0;
};

class PVFirstModel {
public:
    PowerSplit apply(double P_job, double P_pv) const;
};
