#ifndef ENERGY_MODEL_HPP
#define ENERGY_MODEL_HPP

#include "model/PVFirstModel.hpp"

struct EnergyStats {
    double E_total = 0.0;
    double E_pv    = 0.0;
    double E_grid  = 0.0;
    double CO2     = 0.0;
};

class EnergyModel {
public:
    EnergyModel(double carbonIntensity);

    void update(double P_job,
                double P_pv,
                double delta_t_seconds);

    // Esta funcao usa diretamente a energia medida pelo SimGrid.
    // Assim o PV-First divide a demanda energetica simulada entre PV e rede.
    void updateFromSimGridEnergy(double simgridEnergyKWh,
                                 double pvPowerKW,
                                 double durationSeconds);

    EnergyStats getStats() const;

private:
    double CI_grid;
    EnergyStats stats;
    PVFirstModel pvFirstModel;
};

#endif
