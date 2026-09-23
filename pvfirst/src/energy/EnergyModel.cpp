#include "EnergyModel.hpp"

EnergyModel::EnergyModel(double carbonIntensity)
    : CI_grid(carbonIntensity)
{
}

void EnergyModel::update(double P_job,
                         double P_pv,
                         double delta_t_seconds)
{
    double delta_t_hours = delta_t_seconds / 3600.0;

    PowerSplit split = pvFirstModel.apply(P_job, P_pv);

    double E_interval      = P_job * delta_t_hours;
    double E_pv_interval   = split.pv * delta_t_hours;
    double E_grid_interval = split.grid * delta_t_hours;

    stats.E_total += E_interval;
    stats.E_pv    += E_pv_interval;
    stats.E_grid  += E_grid_interval;
    stats.CO2     += E_grid_interval * CI_grid;
}

void EnergyModel::updateFromSimGridEnergy(double simgridEnergyKWh,
                                          double pvPowerKW,
                                          double durationSeconds)
{
    // Aqui a energia total do job vem diretamente do SimGrid.
    // O SimGrid executa a carga em FLOPs e mede o consumo do host.
    // Depois o PV-First calcula quanto dessa energia caberia na PV.

    double delta_t_hours = durationSeconds / 3600.0;
    double pvAvailableKWh = pvPowerKW * delta_t_hours;

    double E_pv_interval = pvAvailableKWh;

    if (E_pv_interval > simgridEnergyKWh)
        E_pv_interval = simgridEnergyKWh;

    if (E_pv_interval < 0.0)
        E_pv_interval = 0.0;

    double E_grid_interval = simgridEnergyKWh - E_pv_interval;

    if (E_grid_interval < 0.0)
        E_grid_interval = 0.0;

    stats.E_total += simgridEnergyKWh;
    stats.E_pv    += E_pv_interval;
    stats.E_grid  += E_grid_interval;
    stats.CO2     += E_grid_interval * CI_grid;
}

EnergyStats EnergyModel::getStats() const
{
    return stats;
}
