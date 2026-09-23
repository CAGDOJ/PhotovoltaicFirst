#include "SimulationController.hpp"
#include "SimGridJobRunner.hpp"
#include "sensors/GeoSensor.hpp"
#include "sensors/MetarSensor.hpp"
#include "sensors/SolarModel.hpp"

#include <cstdlib>
#include <ctime>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <vector>

namespace
{
    // Aqui eu converti o tipo de material em um fator multiplicador simples.
    // A base do projeto continua sendo a eficiencia configurada em baseEfficiency.
    // O material ajusta essa base para representar paineis diferentes sem complicar demais o modelo.
    double getPanelMaterialFactor(const std::string& material)
    {
        if (material == "monocrystalline")
            return 1.00;

        if (material == "polycrystalline")
            return 0.90;

        if (material == "thinfilm")
            return 0.65;

        // Se vier um texto inesperado, eu nao travo o programa.
        // So volto para um fator neutro.
        return 1.00;
    }

    // Aqui eu trato o efeito de monofacial ou bifacial.
    // Se for bifacial, eu aplico um ganho extra configuravel.
    double getPanelFaceGain(const std::string& faceType, double bifacialGainFactor)
    {
        if (faceType == "bifacial")
            return bifacialGainFactor;

        return 1.0;
    }

    std::string getEnvString(const char* name, const std::string& defaultValue)
    {
        const char* value = std::getenv(name);
        if (value == nullptr || std::string(value).empty())
            return defaultValue;
        return std::string(value);
    }

    double getEnvDouble(const char* name, double defaultValue)
    {
        const char* value = std::getenv(name);
        if (value == nullptr || std::string(value).empty())
            return defaultValue;

        try {
            return std::stod(value);
        }
        catch (...) {
            return defaultValue;
        }
    }

    std::string getSimulationProfileLabel(const std::string& profileId)
    {
        if (profileId == "datacenter_moderate") return "Data Center - Moderado";
        if (profileId == "datacenter_high") return "Data Center - Alta Carga";
        if (profileId == "hpc_high") return "HPC - Alta Carga";
        if (profileId == "hpc_extreme") return "HPC - Extremo";
        return profileId;
    }

    int getEnvInt(const char* name, int defaultValue)
    {
        const char* value = std::getenv(name);
        if (value == nullptr || std::string(value).empty())
            return defaultValue;

        try {
            return std::stoi(value);
        }
        catch (...) {
            return defaultValue;
        }
    }

    SimulationConfig loadConfigFromEnvironment()
    {
        SimulationConfig cfg;

        cfg.simulationProfile = getEnvString("PVFIRST_SIMULATION_PROFILE", cfg.simulationProfile);
        cfg.defaultJobFlops = getEnvDouble("PVFIRST_DEFAULT_FLOPS", cfg.defaultJobFlops);
        cfg.gridCarbonIntensity = getEnvDouble("PVFIRST_GRID_CARBON_INTENSITY", cfg.gridCarbonIntensity);

        cfg.pv.panelMaterial = getEnvString("PVFIRST_PANEL_MATERIAL", cfg.pv.panelMaterial);
        cfg.pv.panelFaceType = getEnvString("PVFIRST_PANEL_FACE_TYPE", cfg.pv.panelFaceType);
        cfg.pv.panelAreaM2 = getEnvDouble("PVFIRST_PANEL_AREA_M2", cfg.pv.panelAreaM2);
        cfg.pv.baseEfficiency = getEnvDouble("PVFIRST_PANEL_BASE_EFFICIENCY", cfg.pv.baseEfficiency);
        cfg.pv.bifacialGainFactor = getEnvDouble("PVFIRST_BIFACIAL_GAIN", cfg.pv.bifacialGainFactor);

        cfg.datacenter.activeServers = getEnvInt("PVFIRST_DC_ACTIVE_SERVERS", cfg.datacenter.activeServers);
        if (cfg.datacenter.activeServers < 1)
            cfg.datacenter.activeServers = 1;

        cfg.datacenter.pue = getEnvDouble("PVFIRST_DC_PUE", cfg.datacenter.pue);
        if (cfg.datacenter.pue < 1.0)
            cfg.datacenter.pue = 1.0;

        cfg.datacenter.networkPowerKW = getEnvDouble("PVFIRST_DC_NETWORK_KW", cfg.datacenter.networkPowerKW);
        if (cfg.datacenter.networkPowerKW < 0.0)
            cfg.datacenter.networkPowerKW = 0.0;

        cfg.datacenter.storagePowerKW = getEnvDouble("PVFIRST_DC_STORAGE_KW", cfg.datacenter.storagePowerKW);
        if (cfg.datacenter.storagePowerKW < 0.0)
            cfg.datacenter.storagePowerKW = 0.0;

        return cfg;
    }

    struct DailyEnergySummary
    {
        double totalKWh = 0.0;
        double photovoltaicKWh = 0.0;
        double gridKWh = 0.0;
        double co2GridG = 0.0;
        double co2WithoutPVG = 0.0;
        double co2AvoidedG = 0.0;
        int records = 0;
    };

    std::vector<std::string> splitCsvLine(const std::string& line, char sep)
    {
        std::vector<std::string> parts;
        std::string current;
        bool insideQuotes = false;

        for (char ch : line) {
            if (ch == '"') {
                insideQuotes = !insideQuotes;
                continue;
            }

            if (ch == sep && !insideQuotes) {
                parts.push_back(current);
                current.clear();
            }
            else {
                current += ch;
            }
        }

        parts.push_back(current);
        return parts;
    }

    double parseCsvDouble(const std::string& text)
    {
        std::string normalized = text;
        for (char& ch : normalized) {
            if (ch == ',')
                ch = '.';
        }

        try {
            return std::stod(normalized);
        }
        catch (...) {
            return 0.0;
        }
    }

    int findColumnIndex(const std::vector<std::string>& header, const std::string& name)
    {
        for (size_t i = 0; i < header.size(); ++i) {
            if (header[i] == name)
                return static_cast<int>(i);
        }

        return -1;
    }

    double getColumnValue(const std::vector<std::string>& row, int index)
    {
        if (index < 0 || static_cast<size_t>(index) >= row.size())
            return 0.0;

        return parseCsvDouble(row[static_cast<size_t>(index)]);
    }

    DailyEnergySummary calculateDailySummary(const std::filesystem::path& resultsFilePath,
                                             double carbonIntensity)
    {
        DailyEnergySummary summary;

        std::ifstream file(resultsFilePath);
        if (!file.is_open())
            return summary;

        std::string headerLine;
        if (!std::getline(file, headerLine))
            return summary;

        char sep = ';';
        if (headerLine.find(';') == std::string::npos && headerLine.find(',') != std::string::npos)
            sep = ',';

        std::vector<std::string> header = splitCsvLine(headerLine, sep);

        int totalIndex = findColumnIndex(header, "energy_total_kwh");
        int pvIndex = findColumnIndex(header, "energy_pv_kwh");
        int gridIndex = findColumnIndex(header, "energy_grid_kwh");
        int co2Index = findColumnIndex(header, "co2_g");
        int co2WithoutPvIndex = findColumnIndex(header, "co2_without_pv_g");
        int co2AvoidedIndex = findColumnIndex(header, "co2_avoided_by_pv_g");

        std::string line;
        while (std::getline(file, line)) {
            if (line.empty())
                continue;

            std::vector<std::string> row = splitCsvLine(line, sep);

            double total = getColumnValue(row, totalIndex);
            double pv = getColumnValue(row, pvIndex);
            double grid = getColumnValue(row, gridIndex);
            double co2Grid = getColumnValue(row, co2Index);

            double co2WithoutPV = getColumnValue(row, co2WithoutPvIndex);
            if (co2WithoutPV == 0.0 && total > 0.0)
                co2WithoutPV = total * carbonIntensity;

            double co2Avoided = getColumnValue(row, co2AvoidedIndex);
            if (co2Avoided == 0.0 && pv > 0.0)
                co2Avoided = pv * carbonIntensity;

            summary.totalKWh += total;
            summary.photovoltaicKWh += pv;
            summary.gridKWh += grid;
            summary.co2GridG += co2Grid;
            summary.co2WithoutPVG += co2WithoutPV;
            summary.co2AvoidedG += co2Avoided;
            summary.records++;
        }

        return summary;
    }
}


SimulationController::SimulationController()
    : config(loadConfigFromEnvironment()),
      model(config.gridCarbonIntensity)
{
}

double SimulationController::parseJobInput(const std::string& input)
{
    // Se eu apertar Enter sem digitar nada, uso o valor padrao configurado.
    if (input.empty())
        return config.defaultJobFlops;

    return std::stod(input);
}

double SimulationController::askJobFlops()
{
    std::string input;

    std::cout << "Digite a carga do job em FLOPs (ex: 5e10).\n";
    std::cout << "Se quiser usar o valor padrao, e so apertar Enter: " << std::flush;
    std::getline(std::cin, input);

    return parseJobInput(input);
}

void SimulationController::run()
{
    std::cout << "\n============================================================\n";
    std::cout << "SIMULACAO PV-FIRST COM JOB DO SIMGRID\n";
    std::cout << "============================================================\n\n";

    std::cout << "Fluxo da simulacao:\n";
    std::cout << "1) eu verifico local, clima e irradiancia solar\n";
    std::cout << "2) o SimGrid executa o job e mede energia, mesmo sem sol\n";
    std::cout << "3) o modelo PV-First prioriza Photovoltaic; se faltar, usa GRID\n\n";

    // ============================== LOCALIZACAO ==============================
    // Aqui eu pego a localizacao atual do experimento.
    // Isso serve de base para o clima e para o calculo solar.
    GeoSensor geo;
    GPSData gps = geo.getLocation();

    // ========================== HORA LOCAL E DIA =============================
    // Aqui eu uso a hora local da maquina.
    // Isso define o dia do ano e a hora decimal que entram no modelo solar.
    std::time_t now = std::time(nullptr);
    std::tm localTime = *std::localtime(&now);

    int dayOfYear = localTime.tm_yday + 1;
    int hourInt   = localTime.tm_hour;
    int minuteInt = localTime.tm_min;
    int secondInt = localTime.tm_sec;

    double hourDecimal = hourInt + minuteInt / 60.0;

    // ========================== CLIMA E IRRADIANCIA ==========================
    // Primeiro eu calculo a irradiancia teorica.
    // Depois puxo os fatores meteorologicos reais.
    SolarModel solar;
    double irradianceTheoreticalWm2 =
        solar.computeIrradiance(gps.latitude, dayOfYear, hourDecimal);

    MetarSensor metar;
    WeatherImpact impact = metar.getWeatherImpact(gps.latitude, gps.longitude);

    // Aqui eu reduzo a irradiancia teorica com os fatores de nuvem e chuva.
    double irradianceAdjustedWm2 =
        irradianceTheoreticalWm2 *
        impact.cloudFactor *
        impact.rainFactor;

    // ======================== PARAMETROS DO PAINEL ===========================
    // Aqui eu aplico a parte modular do painel sem criar arquivo novo.
    // A ideia e:
    // - baseEfficiency representa a eficiencia de referencia do experimento
    // - panelMaterial ajusta essa base para o tipo de tecnologia
    // - panelFaceType ajusta o ganho extra se o painel for bifacial
    double materialFactor =
        getPanelMaterialFactor(config.pv.panelMaterial);

    double effectiveBaseEfficiency =
        config.pv.baseEfficiency * materialFactor;

    double faceGain =
        getPanelFaceGain(
            config.pv.panelFaceType,
            config.pv.bifacialGainFactor
        );

    // Agora eu monto a eficiencia final do arranjo.
    // Primeiro ajusto pela tecnologia do painel.
    // Depois aplico temperatura, vento e eventualmente ganho bifacial.
    double pvEfficiency =
        effectiveBaseEfficiency *
        impact.tempFactor *
        impact.windCoolingFactor *
        faceGain;

    double pvPowerKW =
        pvEfficiency *
        config.pv.panelAreaM2 *
        irradianceAdjustedWm2 / 1000.0;

    if (pvPowerKW < 0.0)
        pvPowerKW = 0.0;

    std::cout << "\n-------------------- DADOS DO LOCAL --------------------\n";
    std::cout << "Cidade detectada : " << gps.city << "\n";
    std::cout << "Latitude         : " << gps.latitude << "\n";
    std::cout << "Longitude        : " << gps.longitude << "\n";
    std::cout << "Hora local       : "
              << std::setfill('0') << std::setw(2) << hourInt << ":"
              << std::setfill('0') << std::setw(2) << minuteInt << ":"
              << std::setfill('0') << std::setw(2) << secondInt << "\n";
    std::cout << "Dia do ano       : " << dayOfYear << "\n";

    std::cout << "\n------------------ CONDICOES DO CLIMA ------------------\n";
    std::cout << "Cobertura nuvens : " << impact.cloudCover << " %\n";
    std::cout << "Chuva            : " << impact.rainAmount << " mm\n";
    std::cout << "Temperatura      : " << impact.temperature << " C\n";
    std::cout << "Vento            : " << impact.windSpeed << " km/h\n";

    std::cout << "\n----------------- PERFIL DA SIMULACAO -------------------\n";
    std::cout << "Perfil selecionado : " << config.simulationProfile << "\n";

    std::cout << "\n----------------- CONFIGURACAO DO PAINEL ----------------\n";
    std::cout << "Material          : " << config.pv.panelMaterial << "\n";
    std::cout << "Face do painel    : " << config.pv.panelFaceType << "\n";
    std::cout << "Area do painel    : " << config.pv.panelAreaM2 << " m2\n";
    std::cout << "Eficiencia base   : " << config.pv.baseEfficiency << "\n";
    std::cout << "Ganho bifacial configurado : " << config.pv.bifacialGainFactor << "\n";
    std::cout << "Ganho aplicado no painel   : " << faceGain << "\n";
    std::cout << "Fator do material : " << materialFactor << "\n";

    std::cout << "\n----------------- PARAMETROS DO DATA CENTER -------------\n";
    std::cout << "Servidores ativos equivalentes : " << config.datacenter.activeServers << "\n";
    std::cout << "PUE do data center             : " << config.datacenter.pue << "\n";
    std::cout << "Carga de rede                  : " << config.datacenter.networkPowerKW << " kW\n";
    std::cout << "Carga de armazenamento         : " << config.datacenter.storagePowerKW << " kW\n";

    std::cout << "\n----------------- MODELO FOTOVOLTAICO ------------------\n";
    std::cout << "Irradiancia teorica      : " << irradianceTheoreticalWm2 << " W/m2\n";
    std::cout << "Irradiancia ajustada     : " << irradianceAdjustedWm2 << " W/m2\n";
    std::cout << "Eficiencia base efetiva  : " << effectiveBaseEfficiency << "\n";
    std::cout << "Eficiencia final arranjo : " << pvEfficiency << "\n";
    std::cout << "Potencia PV disponivel   : " << pvPowerKW << " kW\n";

    // ====================== LEITURA DE IRRADIANCIA ===========================
    // Se nao houver irradiancia util, a geracao fotovoltaica fica zerada.
    // Mesmo assim o job pode ser executado no SimGrid: nesse caso, a demanda
    // energetica sera atendida pela GRID. Isso deixa o comportamento visual
    // mais claro na interface: PV liga quando entrega energia; GRID liga
    // quando precisa complementar ou quando nao existe sol.
    //
    // A palavra PVFIRST_SEM_IRRADIANCIA continua sendo impressa para a coleta
    // solar saber quando deve entrar em standby noturno apos o fim do dia.
    const double irradianceMinimumToRun = getEnvDouble("PVFIRST_IRRADIANCE_MIN_WM2", 1.0); // W/m2
    bool withoutUsefulIrradiance = (irradianceAdjustedWm2 <= irradianceMinimumToRun || pvPowerKW <= 0.0);

    if (withoutUsefulIrradiance) {
        pvPowerKW = 0.0;
        std::cout << "\nPVFIRST_SEM_IRRADIANCIA\n";
        std::cout << "Sem irradiancia util neste instante.\n";
        std::cout << "Photovoltaic : OFF\n";
        std::cout << "GRID         : ON se houver execucao de job\n";
        std::cout << "Modo esperado: GRID atende o job porque a PV nao esta disponivel.\n";
    }

    // ============================= JOB DO SIMGRID ============================
    // Agora o SimGrid executa o job e mede a energia real simulada.
    // Se a PV estiver disponivel, ela entra primeiro. Se nao estiver, a GRID atende.
    double jobFlops = askJobFlops();

    // Aqui o SimGrid continua sendo a fonte oficial da demanda do job.
    // Ou seja: a duracao, a energia e a potencia media saem da simulacao computacional,
    // e nao de um chute feito no controller.
    SimGridJobRunner jobRunner;
    SimGridJobConfig jobConfig;
    jobConfig.jobFlops = jobFlops;

    SimGridJobResult job = jobRunner.run(jobConfig);

    std::cout << "\n--------------------- JOB DO SIMGRID -------------------\n";
    std::cout << "Host usado           : " << job.hostName << "\n";
    std::cout << "Carga do job         : " << job.jobFlops << " FLOPs\n";
    std::cout << "Velocidade do host   : " << job.hostSpeedFlops << " flop/s\n";
    std::cout << "Duracao do job       : " << job.durationSeconds << " s\n";
    std::cout << "Energia do job       : " << job.energyJoules << " J\n";
    std::cout << "Energia do job       : " << job.energyKWh << " kWh\n";
    std::cout << "Potencia media do job: " << job.averagePowerKW << " kW\n";

    // ============================= MODELO DE DATA CENTER =====================
    // O SimGrid mede a energia de TI do job/host.
    // Para aproximar o comportamento de um data center, eu agrego:
    // - varios servidores equivalentes executando carga semelhante;
    // - energia de rede/armazenamento durante a janela do job;
    // - PUE para representar refrigeracao, UPS e perdas de infraestrutura.
    double durationHours = job.durationSeconds / 3600.0;
    double dcComputeITKWh = job.energyKWh * static_cast<double>(config.datacenter.activeServers);
    double dcNetworkKWh = config.datacenter.networkPowerKW * durationHours;
    double dcStorageKWh = config.datacenter.storagePowerKW * durationHours;
    double dcSupportITKWh = dcNetworkKWh + dcStorageKWh;
    double dcTotalITKWh = dcComputeITKWh + dcSupportITKWh;
    double dcFacilityTotalKWh = dcTotalITKWh * config.datacenter.pue;
    double dcFacilityOverheadKWh = dcFacilityTotalKWh - dcTotalITKWh;

    if (dcFacilityOverheadKWh < 0.0)
        dcFacilityOverheadKWh = 0.0;

    std::cout << "\n-------------------- ENERGIA DO DATA CENTER --------------\n";
    std::cout << "Energia IT do job por servidor : " << job.energyKWh << " kWh\n";
    std::cout << "Energia IT computacional       : " << dcComputeITKWh << " kWh\n";
    std::cout << "Energia IT rede                : " << dcNetworkKWh << " kWh\n";
    std::cout << "Energia IT armazenamento       : " << dcStorageKWh << " kWh\n";
    std::cout << "Energia IT total               : " << dcTotalITKWh << " kWh\n";
    std::cout << "Energia infraestrutura/PUE     : " << dcFacilityOverheadKWh << " kWh\n";
    std::cout << "Energia total do data center   : " << dcFacilityTotalKWh << " kWh\n";

    // ============================= TRIAGEM PV-FIRST ==========================
    // Agora o modelo PV-First trabalha sobre a demanda total do data center.
    // Photovoltaic entra primeiro. A GRID so complementa quando a PV nao consegue
    // cobrir toda a energia do data center naquele intervalo.
    model.updateFromSimGridEnergy(dcFacilityTotalKWh, pvPowerKW, job.durationSeconds);
    EnergyStats stats = model.getStats();

    double pvPossibleKWh = pvPowerKW * durationHours;

    // CO2 emitido e CO2 evitado nesta execucao.
    // CO2 emitido pela GRID considera apenas a parcela que realmente veio da rede.
    // CO2 evitado pela PV representa a reducao causada pela energia fotovoltaica usada.
    double co2WithoutPV = stats.E_total * config.gridCarbonIntensity;
    double co2AvoidedByPV = stats.E_pv * config.gridCarbonIntensity;

    std::string sourceMode = "STANDBY";
    std::string photovoltaicStatus = "OFF";
    std::string gridStatus = "OFF";

    if (stats.E_pv > 0.0 && stats.E_grid > 0.0) {
        sourceMode = "PHOTOVOLTAIC+GRID";
        photovoltaicStatus = "ON";
        gridStatus = "ON";
    }
    else if (stats.E_pv > 0.0) {
        sourceMode = "PHOTOVOLTAIC";
        photovoltaicStatus = "ON";
        gridStatus = "OFF";
    }
    else if (stats.E_grid > 0.0) {
        sourceMode = "GRID";
        photovoltaicStatus = "OFF";
        gridStatus = "ON";
    }

    std::cout << "\n-------------------- RESULTADO PV-FIRST ----------------\n";
    std::cout << "Energia total do data center : " << stats.E_total << " kWh\n";
    std::cout << "Energia vinda da PV        : " << stats.E_pv << " kWh\n";
    std::cout << "Energia vinda da GRID      : " << stats.E_grid << " kWh\n";
    std::cout << "CO2 emitido pela GRID      : " << stats.CO2 << " gCO2 nesta execucao\n";
    std::cout << "CO2 evitado pela PV        : " << co2AvoidedByPV << " gCO2 nesta execucao\n";
    std::cout << "CO2 se fosse 100% GRID     : " << co2WithoutPV << " gCO2 nesta execucao\n";

    std::cout << "\n-------------------- FONTE ATENDENDO O JOB --------------\n";
    std::cout << "PHOTOVOLTAIC : " << photovoltaicStatus << "\n";
    std::cout << "GRID         : " << gridStatus << "\n";
    std::cout << "MODO DA FONTE: " << sourceMode << "\n";

    if (sourceMode == "PHOTOVOLTAIC") {
        std::cout << "Leitura da fonte: a energia fotovoltaica foi suficiente; GRID ficou desligada.\n";
    }
    else if (sourceMode == "PHOTOVOLTAIC+GRID") {
        std::cout << "Leitura da fonte: PHOTOVOLTAIC entrou primeiro, mas GRID complementou a energia faltante.\n";
    }
    else if (sourceMode == "GRID") {
        std::cout << "Leitura da fonte: sem energia fotovoltaica suficiente; GRID atendeu o job.\n";
    }

    std::cout << "\nLeitura rapida do experimento:\n";
    std::cout << "- o SimGrid mediu " << job.energyKWh << " kWh por job/servidor\n";
    std::cout << "- o data center demandou " << dcFacilityTotalKWh << " kWh no intervalo\n";
    std::cout << "- a PV poderia entregar ate " << pvPossibleKWh << " kWh nesse mesmo intervalo\n";
    std::cout << "- o modelo PV-First priorizou PHOTOVOLTAIC e usou GRID apenas como complemento\n";

    // ======================== PARAMETROS EFETIVAMENTE USADOS ===================
    // Eu salvo estes valores junto com cada linha do CSV para que cada execucao
    // seja totalmente rastreavel, mesmo quando eu trocar o perfil da interface.
    const std::string simulationProfileLabel = getSimulationProfileLabel(config.simulationProfile);
    const int collectionStartHour = getEnvInt("PVFIRST_SOLAR_START_HOUR", 6);
    const int collectionIntervalSeconds = getEnvInt("PVFIRST_SOLAR_INTERVAL_SECONDS", 60);
    const int standbyZeroLimit = getEnvInt("PVFIRST_SOLAR_ZERO_LIMIT", 5);
    const double configuredIrradianceMinWm2 = getEnvDouble("PVFIRST_IRRADIANCE_MIN_WM2", 1.0);
    const std::string locationModeConfigured = getEnvString("PVFIRST_LOCATION_MODE", "manual");
    const double hostSpeedGFLOPSConfigured = getEnvDouble("PVFIRST_HOST_SPEED_GFLOPS", 50.0);
    const double hostActiveWConfigured = getEnvDouble("PVFIRST_HOST_ACTIVE_W", 250.0);
    const double hostIdleWConfigured = getEnvDouble("PVFIRST_HOST_IDLE_W", 120.0);
    const double hostOffWConfigured = getEnvDouble("PVFIRST_HOST_OFF_W", 10.0);
    const int gitAutoPushConfigured = getEnvInt("PVFIRST_GIT_AUTO_PUSH", 0);
    const std::string gitRemoteConfigured = getEnvString("PVFIRST_GIT_REMOTE", "origin");
    const std::string gitBranchConfigured = getEnvString("PVFIRST_GIT_BRANCH", "main");
    const std::string gitRepoUrlConfigured = getEnvString("PVFIRST_GIT_REPO_URL", "");

        // ================================ CSV ====================================
    // Aqui eu salvo um arquivo por dia dentro da pasta results na raiz do projeto.
    // Agora usei ponto e virgula como separador, porque no Excel em portugues
    // o CSV com virgula costuma abrir todo baguncado.
    //
    // Exemplo:
    // results/RPVfirst170626.csv

    std::filesystem::create_directories("results");

    std::ostringstream fileNameBuilder;
    fileNameBuilder << "RPVfirst"
                    << std::setfill('0') << std::setw(2) << localTime.tm_mday
                    << std::setfill('0') << std::setw(2) << (localTime.tm_mon + 1)
                    << std::setfill('0') << std::setw(2) << ((localTime.tm_year + 1900) % 100)
                    << ".csv";

    std::filesystem::path resultsFilePath =
        std::filesystem::path("results") / fileNameBuilder.str();

    bool fileExists = std::filesystem::exists(resultsFilePath);

    // Se existir um CSV do mesmo dia criado por uma versao antiga sem perfil,
    // eu preservo esse arquivo como legado e inicio um CSV novo com o schema atual.
    if (fileExists) {
        std::ifstream existingFile(resultsFilePath);
        std::string existingHeader;
        std::getline(existingFile, existingHeader);
        existingFile.close();

        if (existingHeader.find("simulation_profile") == std::string::npos) {
            std::filesystem::path legacyPath = resultsFilePath;
            legacyPath += ".schema_antigo";
            int suffix = 1;
            while (std::filesystem::exists(legacyPath)) {
                legacyPath = resultsFilePath;
                legacyPath += ".schema_antigo_" + std::to_string(suffix++);
            }
            std::filesystem::rename(resultsFilePath, legacyPath);
            fileExists = false;
            std::cout << "CSV anterior preservado em: " << legacyPath.string() << "\n";
        }
    }

    std::ofstream file(resultsFilePath, std::ios::app);

    if (!file.is_open()) {
        throw std::runtime_error(
            "Nao consegui abrir ou criar o arquivo de resultados em: " +
            resultsFilePath.string()
        );
    }

    std::ostringstream runDateBuilder;
    runDateBuilder << (localTime.tm_year + 1900) << "-"
                   << std::setfill('0') << std::setw(2) << (localTime.tm_mon + 1) << "-"
                   << std::setfill('0') << std::setw(2) << localTime.tm_mday;

    std::ostringstream runTimeBuilder;
    runTimeBuilder << std::setfill('0') << std::setw(2) << hourInt << ":"
                   << std::setfill('0') << std::setw(2) << minuteInt << ":"
                   << std::setfill('0') << std::setw(2) << secondInt;

    std::ostringstream runDateTimeBuilder;
    runDateTimeBuilder << runDateBuilder.str() << " " << runTimeBuilder.str();

    std::ostringstream runIdBuilder;
    runIdBuilder << "run_"
                 << (localTime.tm_year + 1900)
                 << std::setfill('0') << std::setw(2) << (localTime.tm_mon + 1)
                 << std::setfill('0') << std::setw(2) << localTime.tm_mday
                 << "_"
                 << std::setfill('0') << std::setw(2) << hourInt
                 << std::setfill('0') << std::setw(2) << minuteInt
                 << std::setfill('0') << std::setw(2) << secondInt;

    const char sep = ';';

    if (!fileExists) {
        file << "run_id" << sep
             << "run_date" << sep
             << "run_time" << sep
             << "run_datetime" << sep
             << "day_of_year" << sep
             << "simulation_profile_id" << sep
             << "simulation_profile" << sep
             << "collection_start_hour" << sep
             << "collection_interval_s" << sep
             << "standby_zero_limit_readings" << sep
             << "irradiance_min_w_m2" << sep
             << "location_mode" << sep
             << "host_speed_gflops_configured" << sep
             << "host_power_active_w" << sep
             << "host_power_idle_w" << sep
             << "host_power_off_w" << sep
             << "git_auto_push" << sep
             << "git_remote" << sep
             << "git_branch" << sep
             << "git_repo_url" << sep
             << "city" << sep
             << "latitude" << sep
             << "longitude" << sep
             << "panel_material" << sep
             << "panel_face_type" << sep
             << "panel_area_m2" << sep
             << "panel_base_efficiency" << sep
             << "panel_material_factor" << sep
             << "panel_effective_base_efficiency" << sep
             << "panel_bifacial_gain_configured" << sep
             << "panel_face_gain_applied" << sep
             << "cloud_cover_pct" << sep
             << "rain_mm" << sep
             << "temperature_c" << sep
             << "wind_speed_kmh" << sep
             << "irradiance_theoretical_w_m2" << sep
             << "irradiance_adjusted_w_m2" << sep
             << "pv_efficiency" << sep
             << "pv_power_kw" << sep
             << "grid_carbon_intensity_gco2_kwh" << sep
             << "dc_active_servers" << sep
             << "dc_pue" << sep
             << "dc_network_kw" << sep
             << "dc_storage_kw" << sep
             << "dc_it_compute_kwh" << sep
             << "dc_it_support_kwh" << sep
             << "dc_it_total_kwh" << sep
             << "dc_facility_overhead_kwh" << sep
             << "dc_facility_total_kwh" << sep
             << "job_flops" << sep
             << "job_duration_s" << sep
             << "job_energy_j" << sep
             << "job_energy_kwh" << sep
             << "job_average_power_kw" << sep
             << "energy_total_kwh" << sep
             << "energy_pv_kwh" << sep
             << "energy_grid_kwh" << sep
             << "co2_g" << sep
             << "co2_without_pv_g" << sep
             << "co2_avoided_by_pv_g" << sep
             << "source_mode" << sep
             << "photovoltaic_status" << sep
             << "grid_status\n";
    }

    file << runIdBuilder.str() << sep
         << runDateBuilder.str() << sep
         << runTimeBuilder.str() << sep
         << runDateTimeBuilder.str() << sep
         << dayOfYear << sep
         << "\"" << config.simulationProfile << "\"" << sep
         << "\"" << simulationProfileLabel << "\"" << sep
         << collectionStartHour << sep
         << collectionIntervalSeconds << sep
         << standbyZeroLimit << sep
         << configuredIrradianceMinWm2 << sep
         << "\"" << locationModeConfigured << "\"" << sep
         << hostSpeedGFLOPSConfigured << sep
         << hostActiveWConfigured << sep
         << hostIdleWConfigured << sep
         << hostOffWConfigured << sep
         << gitAutoPushConfigured << sep
         << "\"" << gitRemoteConfigured << "\"" << sep
         << "\"" << gitBranchConfigured << "\"" << sep
         << "\"" << gitRepoUrlConfigured << "\"" << sep
         << "\"" << gps.city << "\"" << sep
         << gps.latitude << sep
         << gps.longitude << sep
         << "\"" << config.pv.panelMaterial << "\"" << sep
         << "\"" << config.pv.panelFaceType << "\"" << sep
         << config.pv.panelAreaM2 << sep
         << config.pv.baseEfficiency << sep
         << materialFactor << sep
         << effectiveBaseEfficiency << sep
         << config.pv.bifacialGainFactor << sep
         << faceGain << sep
         << impact.cloudCover << sep
         << impact.rainAmount << sep
         << impact.temperature << sep
         << impact.windSpeed << sep
         << irradianceTheoreticalWm2 << sep
         << irradianceAdjustedWm2 << sep
         << pvEfficiency << sep
         << pvPowerKW << sep
         << config.gridCarbonIntensity << sep
         << config.datacenter.activeServers << sep
         << config.datacenter.pue << sep
         << config.datacenter.networkPowerKW << sep
         << config.datacenter.storagePowerKW << sep
         << dcComputeITKWh << sep
         << dcSupportITKWh << sep
         << dcTotalITKWh << sep
         << dcFacilityOverheadKWh << sep
         << dcFacilityTotalKWh << sep
         << job.jobFlops << sep
         << job.durationSeconds << sep
         << job.energyJoules << sep
         << job.energyKWh << sep
         << job.averagePowerKW << sep
         << stats.E_total << sep
         << stats.E_pv << sep
         << stats.E_grid << sep
         << stats.CO2 << sep
         << co2WithoutPV << sep
         << co2AvoidedByPV << sep
         << sourceMode << sep
         << photovoltaicStatus << sep
         << gridStatus << "\n";

    file.close();

    DailyEnergySummary daily =
        calculateDailySummary(resultsFilePath, config.gridCarbonIntensity);

    std::cout << "\nDados salvos em: "
              << resultsFilePath.string() << "\n";

    std::cout << "\n-------------------- RESUMO DE CARBONO DO DIA ------------\n";
    std::cout << "Registros do dia           : " << daily.records << "\n";
    std::cout << "Energia total do dia       : " << daily.totalKWh << " kWh\n";
    std::cout << "Energia PV no dia          : " << daily.photovoltaicKWh << " kWh\n";
    std::cout << "Energia GRID no dia        : " << daily.gridKWh << " kWh\n";
    std::cout << "CO2 emitido pela GRID      : " << daily.co2GridG << " gCO2 no dia\n";
    std::cout << "CO2 que emitiria sem PV    : " << daily.co2WithoutPVG << " gCO2 no dia\n";
    std::cout << "CO2 reduzido pela PV       : " << daily.co2AvoidedG << " gCO2 no dia\n";

    std::cout << "\n============================================================\n";
    std::cout << "SIMULACAO FINALIZADA\n";
    std::cout << "============================================================\n";
}