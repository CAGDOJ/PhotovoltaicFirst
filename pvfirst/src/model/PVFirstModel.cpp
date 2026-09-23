#include "PVFirstModel.hpp"
#include <algorithm>

PowerSplit PVFirstModel::apply(double P_job, double P_pv) const
{
    // O modelo PV-First prioriza a potencia fotovoltaica disponivel.
    // A rede eletrica fornece apenas a parcela complementar da demanda.
    PowerSplit split;
    split.pv   = std::min(P_job, P_pv);
    split.grid = P_job - split.pv;
    return split;
}
