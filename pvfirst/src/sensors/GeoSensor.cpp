#include "GeoSensor.hpp"

#include <curl/curl.h>

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <iostream>
#include <string>
#include <thread>

static size_t WriteCallback(void* contents,
                            size_t size,
                            size_t nmemb,
                            std::string* output)
{
    size_t total = size * nmemb;
    output->append(static_cast<char*>(contents), total);
    return total;
}


static std::string shellQuote(const std::string& s)
{
    std::string out = "'";
    for (char c : s) {
        if (c == '\'') out += "'\\\"'\\\"'";
        else out += c;
    }
    out += "'";
    return out;
}

static bool fetchViaWindowsProxy(const std::string& url, std::string& response)
{
    const char* autoProxy = std::getenv("PVFIRST_PROXY_AUTO");
    const char* proxy = std::getenv("PVFIRST_PROXY_URL");
    if (autoProxy == nullptr || std::string(autoProxy) != "1" || proxy == nullptr || std::string(proxy).empty())
        return false;

    std::string command =
        "powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File \"$(wslpath -w ./_launcher/windows_fetch.ps1)\" -Url " +
        shellQuote(url) + " -Proxy " + shellQuote(proxy) + " 2>/dev/null";

    FILE* pipe = popen(command.c_str(), "r");
    if (pipe == nullptr)
        return false;

    char buffer[4096];
    std::string data;
    while (fgets(buffer, sizeof(buffer), pipe) != nullptr)
        data += buffer;
    int rc = pclose(pipe);
    if (rc == 0 && !data.empty()) {
        response = data;
        return true;
    }
    return false;
}

static double extractNumber(const std::string& json, const std::string& key, double defaultValue)
{
    auto keyPos = json.find(key);
    if (keyPos == std::string::npos)
        return defaultValue;

    auto start = json.find(":", keyPos);
    if (start == std::string::npos)
        return defaultValue;

    start++;
    auto end = json.find_first_of(",}", start);

    try {
        return std::stod(json.substr(start, end - start));
    }
    catch (...) {
        return defaultValue;
    }
}

static std::string extractText(const std::string& json, const std::string& keyPrefix, const std::string& defaultValue)
{
    auto keyPos = json.find(keyPrefix);
    if (keyPos == std::string::npos)
        return defaultValue;

    auto start = keyPos + keyPrefix.size();
    auto end = json.find('"', start);
    if (end == std::string::npos)
        return defaultValue;

    return json.substr(start, end - start);
}


static std::string getEnvText(const char* name, const std::string& defaultValue)
{
    const char* value = std::getenv(name);
    if (value == nullptr || std::string(value).empty())
        return defaultValue;
    return std::string(value);
}

static double getEnvNumber(const char* name, double defaultValue)
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

static bool useManualLocation()
{
    std::string mode = getEnvText("PVFIRST_LOCATION_MODE", "manual");
    return mode == "manual" || mode == "MANUAL" || mode == "Manual";
}

static bool hasValidLocationPayload(const std::string& response)
{
    return response.find("\"lat\"") != std::string::npos &&
           response.find("\"lon\"") != std::string::npos;
}

GPSData GeoSensor::getLocation()
{
    GPSData gps;

    // Por padrao, o PV-First usa localizacao manual para evitar erro de geolocalizacao por IP.
    // A geolocalizacao por IP pode indicar outra cidade por causa de operadora, VPN, proxy ou roteamento.
    if (useManualLocation()) {
        gps.city = getEnvText("PVFIRST_LOCATION_CITY", gps.city);
        gps.latitude = getEnvNumber("PVFIRST_LOCATION_LATITUDE", gps.latitude);
        gps.longitude = getEnvNumber("PVFIRST_LOCATION_LONGITUDE", gps.longitude);

        std::cout << "Localizacao configurada manualmente: "
                  << gps.city << " (" << gps.latitude << ", " << gps.longitude << ")\n";
        return gps;
    }

    while (true)
    {
        CURL* curl = curl_easy_init();
        if (curl == nullptr) {
            std::cout << "Nao consegui iniciar o CURL para geolocalizacao. Vou tentar novamente em 10 segundos.\n";
            std::this_thread::sleep_for(std::chrono::seconds(10));
            continue;
        }

        std::string response;

        curl_easy_setopt(curl, CURLOPT_URL, "http://ip-api.com/json/");
        curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, WriteCallback);
        curl_easy_setopt(curl, CURLOPT_WRITEDATA, &response);
        curl_easy_setopt(curl, CURLOPT_TIMEOUT, 10L);
        curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT, 5L);
        curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 1L);
        curl_easy_setopt(curl, CURLOPT_NOSIGNAL, 1L);

        CURLcode res = curl_easy_perform(curl);

        long httpCode = 0;
        curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &httpCode);

        curl_easy_cleanup(curl);

        if (!(res == CURLE_OK && httpCode >= 200 && httpCode < 300 && hasValidLocationPayload(response))) {
            std::string winResponse;
            if (fetchViaWindowsProxy("http://ip-api.com/json/", winResponse) && hasValidLocationPayload(winResponse))
                response = winResponse;
        }

        if (hasValidLocationPayload(response)) {
            gps.latitude  = extractNumber(response, "\"lat\"", gps.latitude);
            gps.longitude = extractNumber(response, "\"lon\"", gps.longitude);
            gps.city      = extractText(response, "\"city\":\"", gps.city);
            return gps;
        }

        std::cout << "Sem conectividade valida para geolocalizacao. Vou tentar novamente em 10 segundos.\n";
        std::this_thread::sleep_for(std::chrono::seconds(10));
    }
}