#!/usr/bin/env python3
# Dashboard HTML do PV-First.
# Usa apenas biblioteca padrao do Python para evitar instalacao pesada de pacotes.

from __future__ import annotations

import base64
import csv
import json
import os
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RESULTS_DIR = ROOT / "results"
DASH_DIR = ROOT / "dashboard"
ASSETS_DIR = DASH_DIR / "assets"
OUT_HTML = DASH_DIR / "pvfirst_dashboard.html"
LOGO_PATH = ASSETS_DIR / "PVfirst.png"
GRID_ICON_PATH = ASSETS_DIR / "grid.png"
PV_ICON_PATH = ASSETS_DIR / "photovoltaic.jpg"

NUMERIC_COLUMNS = {
    "day_of_year", "latitude", "longitude", "panel_area_m2", "panel_base_efficiency",
    "panel_material_factor", "panel_effective_base_efficiency", "panel_bifacial_gain_factor",
    "panel_bifacial_gain_configured", "panel_face_gain_applied", "cloud_cover_pct",
    "rain_mm", "temperature_c", "wind_speed_kmh", "irradiance_theoretical_w_m2",
    "irradiance_adjusted_w_m2", "pv_efficiency", "pv_power_kw",
    "grid_carbon_intensity_gco2_kwh", "job_flops", "job_duration_s", "job_energy_j",
    "job_energy_kwh", "job_average_power_kw", "energy_total_kwh", "energy_pv_kwh",
    "energy_grid_kwh", "co2_g",
    "dc_active_servers", "dc_pue", "dc_network_kw", "dc_storage_kw",
    "dc_it_compute_kwh", "dc_it_support_kwh", "dc_it_total_kwh",
    "dc_facility_overhead_kwh", "dc_facility_total_kwh",
}


def detect_sep(line: str) -> str:
    semicolons = line.count(";")
    commas = line.count(",")
    return ";" if semicolons >= commas else ","


def parse_float(value):
    if value is None:
        return 0.0
    if isinstance(value, (int, float)):
        return float(value)
    txt = str(value).strip().replace('"', '')
    if txt == "":
        return 0.0
    # Aceita numero brasileiro se vier com virgula decimal.
    # Nao mexe em datas/horas porque so chamamos isto para colunas numericas.
    txt = txt.replace(",", ".")
    try:
        return float(txt)
    except Exception:
        return 0.0


def read_one_csv(path: Path):
    try:
        raw = path.read_text(encoding="utf-8-sig", errors="replace").splitlines()
    except Exception:
        return []
    if not raw:
        return []
    sep = detect_sep(raw[0])
    rows = []
    reader = csv.DictReader(raw, delimiter=sep)
    for idx, row in enumerate(reader, start=1):
        if not row:
            continue
        clean = {}
        for key, value in row.items():
            if key is None:
                continue
            k = str(key).strip()
            v = "" if value is None else str(value).strip().strip('"')
            if k in NUMERIC_COLUMNS:
                clean[k] = parse_float(v)
            else:
                clean[k] = v
        clean["source_file"] = str(path.relative_to(ROOT)).replace("\\", "/")
        clean["source_line"] = idx + 1
        rows.append(clean)
    return rows


def load_rows():
    rows = []
    if RESULTS_DIR.exists():
        for path in sorted(RESULTS_DIR.rglob("*.csv")):
            rows.extend(read_one_csv(path))

    def sort_key(r):
        dt = r.get("run_datetime", "")
        if dt:
            return dt
        return f"{r.get('run_date','')} {r.get('run_time','')}"

    rows.sort(key=sort_key)
    return rows


def fmt(v, decimals=6):
    try:
        value = float(v)
    except Exception:
        value = 0.0
    if abs(value) >= 1000:
        return f"{value:,.2f}".replace(",", "X").replace(".", ",").replace("X", ".")
    return f"{value:.{decimals}f}".replace(".", ",")


def file_data_uri(path: Path, mime: str):
    if not path.exists():
        return ""
    data = base64.b64encode(path.read_bytes()).decode("ascii")
    return f"data:{mime};base64,{data}"


def logo_data_uri():
    return file_data_uri(LOGO_PATH, "image/png")


def build_html(rows):
    total = len(rows)
    latest = rows[-1] if rows else {}
    sum_total = sum(parse_float(r.get("energy_total_kwh")) for r in rows)
    sum_pv = sum(parse_float(r.get("energy_pv_kwh")) for r in rows)
    sum_grid = sum(parse_float(r.get("energy_grid_kwh")) for r in rows)
    sum_co2 = sum(parse_float(r.get("co2_g")) for r in rows)
    sum_co2_without_pv = sum(parse_float(r.get("co2_without_pv_g")) for r in rows)
    sum_co2_avoided = sum(parse_float(r.get("co2_avoided_by_pv_g")) for r in rows)

    # Compatibilidade com CSV antigo que ainda nao tinha as colunas novas.
    if sum_co2_without_pv == 0.0 and sum_total > 0.0:
        carbon = parse_float(latest.get("grid_carbon_intensity_gco2_kwh")) if latest else 100.0
        sum_co2_without_pv = sum_total * carbon
    if sum_co2_avoided == 0.0 and sum_pv > 0.0:
        carbon = parse_float(latest.get("grid_carbon_intensity_gco2_kwh")) if latest else 100.0
        sum_co2_avoided = sum_pv * carbon

    pv_share = (sum_pv / sum_total * 100.0) if sum_total > 0 else 0.0

    data_json = json.dumps(rows, ensure_ascii=False)
    logo = logo_data_uri()
    grid_icon = file_data_uri(GRID_ICON_PATH, "image/png")
    pv_icon = file_data_uri(PV_ICON_PATH, "image/jpeg")
    generated = datetime.now().strftime("%d/%m/%Y %H:%M:%S")

    latest_pv = parse_float(latest.get("energy_pv_kwh")) if latest else 0.0
    latest_grid = parse_float(latest.get("energy_grid_kwh")) if latest else 0.0
    latest_source = latest.get("source_mode", "-") if latest else "-"
    pv_state = "ATIVO" if latest_pv > 0 else "OFF"
    grid_state = "ATIVO" if latest_grid > 0 else "OFF"

    latest_rows = rows[-80:][::-1]
    table_rows = []
    for r in latest_rows:
        table_rows.append(
            "<tr>"
            f"<td>{r.get('run_date','')}</td>"
            f"<td>{r.get('run_time','')}</td>"
            f"<td>{r.get('city','')}</td>"
            f"<td>{fmt(r.get('irradiance_adjusted_w_m2'), 2)}</td>"
            f"<td>{fmt(r.get('pv_power_kw'), 4)}</td>"
            f"<td>{fmt(r.get('job_energy_kwh'), 8)}</td>"
            f"<td>{fmt(r.get('energy_pv_kwh'), 8)}</td>"
            f"<td>{fmt(r.get('energy_grid_kwh'), 8)}</td>"
            f"<td>{fmt(r.get('co2_g'), 6)}</td>"
            f"<td>{r.get('source_mode','')}</td>"
            f"<td>{r.get('source_file','')}</td>"
            "</tr>"
        )

    logo_html = f'<img class="logo" src="{logo}" alt="PVFirst">' if logo else '<div class="logoText">PVFirst</div>'

    return f"""<!doctype html>
<html lang="pt-BR">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>PV-First</title>
<style>
:root {{ --navy:#0b2d5c; --blue:#08a9e6; --gold:#f5b400; --bg:#f4f7fb; --card:#ffffff; --text:#172033; }}
* {{ box-sizing:border-box; }}
body {{ margin:0; font-family:Segoe UI, Arial, sans-serif; background:var(--bg); color:var(--text); }}
header {{ background:linear-gradient(135deg, #ffffff 0%, #eef9ff 48%, #fff7d7 100%); border-bottom:1px solid #dde6ef; padding:20px 28px; display:flex; align-items:center; gap:22px; }}
.logo {{ width:118px; height:118px; object-fit:contain; border-radius:18px; background:#fff; box-shadow:0 6px 18px rgba(0,0,0,.09); padding:8px; }}
.logoText {{ font-size:34px; font-weight:900; color:var(--navy); }}
h1 {{ margin:0; color:var(--navy); font-size:34px; line-height:1.1; }}
.sub {{ margin-top:8px; color:#506173; font-size:15px; }}
.actions {{ margin-top:14px; display:flex; gap:10px; flex-wrap:wrap; }}
button, .btn {{ border:0; padding:10px 14px; border-radius:10px; background:var(--navy); color:white; font-weight:700; cursor:pointer; text-decoration:none; display:inline-block; }}
button.secondary, .btn.secondary {{ background:var(--blue); }}
main {{ padding:24px; max-width:1320px; margin:0 auto; }}
.cards {{ display:grid; grid-template-columns:repeat(5, 1fr); gap:14px; margin-bottom:22px; }}
.card {{ background:var(--card); border:1px solid #e1e8f0; border-radius:16px; padding:16px; box-shadow:0 6px 18px rgba(20,45,80,.06); }}
.card .label {{ color:#69798b; font-size:13px; margin-bottom:8px; }}
.card .value {{ font-size:24px; font-weight:900; color:var(--navy); }}
.grid {{ display:grid; grid-template-columns:1fr 1fr; gap:18px; }}
.panel {{ background:var(--card); border:1px solid #e1e8f0; border-radius:16px; padding:18px; box-shadow:0 6px 18px rgba(20,45,80,.06); }}
.panel h2 {{ margin:0 0 14px; color:var(--navy); font-size:20px; }}
canvas {{ width:100%; height:290px; border-radius:10px; background:#fbfdff; border:1px solid #edf2f8; }}
table {{ width:100%; border-collapse:collapse; font-size:13px; }}
th {{ background:#0b2d5c; color:white; position:sticky; top:0; }}
th, td {{ padding:8px 9px; border-bottom:1px solid #e5edf5; text-align:left; white-space:nowrap; }}
.tablewrap {{ overflow:auto; max-height:430px; border:1px solid #e1e8f0; border-radius:12px; }}
.footer {{ color:#6a798a; font-size:12px; margin-top:18px; }}
.badge {{ background:#eaf8ff; color:#0578aa; padding:6px 10px; border-radius:999px; font-size:13px; font-weight:700; display:inline-block; }}
.sourceCards {{ display:grid; grid-template-columns:1fr 1fr; gap:14px; margin-bottom:22px; }}
.sourceCard {{ display:flex; align-items:center; gap:14px; background:white; border:1px solid #e1e8f0; border-radius:16px; padding:14px; box-shadow:0 6px 18px rgba(20,45,80,.06); }}
.sourceCard img {{ width:76px; height:64px; object-fit:contain; }}
.sourceCard h3 {{ margin:0; color:var(--navy); font-size:20px; }}
.sourceCard .state {{ display:inline-block; margin-top:7px; padding:5px 10px; border-radius:999px; font-weight:900; font-size:12px; }}
.on {{ background:#e8f7ed; color:#1f7a3f; }}
.off {{ background:#fdecec; color:#b42318; }}
@media (max-width:1000px) {{ .cards {{ grid-template-columns:1fr 1fr; }} .grid {{ grid-template-columns:1fr; }} header {{ flex-direction:column; align-items:flex-start; }} }}
</style>
</head>
<body>
<header>
  {logo_html}
  <div>
    <h1>PV-First</h1>
    <div class="sub">Energia solar em primeiro lugar - acompanhamento visual das simulacoes e coletas.</div>
    <div class="actions">
      <button onclick="location.reload()">Atualizar painel</button>
      <a class="btn secondary" href="../results/">Abrir pasta results</a>
      <span class="badge">Gerado em {generated}</span>
    </div>
  </div>
</header>
<main>
  <section class="cards">
    <div class="card"><div class="label">Registros carregados</div><div class="value">{total}</div></div>
    <div class="card"><div class="label">Energia total</div><div class="value">{fmt(sum_total, 6)} kWh</div></div>
    <div class="card"><div class="label">Energia PV</div><div class="value">{fmt(sum_pv, 6)} kWh</div></div>
    <div class="card"><div class="label">Energia da rede</div><div class="value">{fmt(sum_grid, 6)} kWh</div></div>
    <div class="card"><div class="label">CO2 reduzido no dia</div><div class="value">{fmt(sum_co2_avoided, 6)} g</div></div>
  </section>

  <section class="cards">
    <div class="card"><div class="label">Participação PV</div><div class="value">{fmt(pv_share, 2)}%</div></div>
    <div class="card"><div class="label">Última cidade</div><div class="value">{latest.get('city','-')}</div></div>
    <div class="card"><div class="label">Última irradiância</div><div class="value">{fmt(latest.get('irradiance_adjusted_w_m2'), 2)} W/m²</div></div>
    <div class="card"><div class="label">Última potência PV</div><div class="value">{fmt(latest.get('pv_power_kw'), 4)} kW</div></div>
    <div class="card"><div class="label">Última execução</div><div class="value">{latest.get('run_time','-')}</div></div>
  </section>

  <section class="cards">
    <div class="card"><div class="label">CO2 emitido pela GRID no dia</div><div class="value">{fmt(sum_co2, 6)} g</div></div>
    <div class="card"><div class="label">CO2 se fosse 100% GRID</div><div class="value">{fmt(sum_co2_without_pv, 6)} g</div></div>
    <div class="card"><div class="label">CO2 evitado pela PV</div><div class="value">{fmt(sum_co2_avoided, 6)} g</div></div>
    <div class="card"><div class="label">GRID entra como complemento</div><div class="value">{'SIM' if sum_grid > 0 else 'NAO'}</div></div>
    <div class="card"><div class="label">Modo PV-First</div><div class="value">PV primeiro</div></div>
  </section>


  <section class="sourceCards">
    <div class="sourceCard">
      {f'<img src="{pv_icon}" alt="Photovoltaic">' if pv_icon else ''}
      <div><h3>PHOTOVOLTAIC</h3><span class="state {'on' if pv_state == 'ATIVO' else 'off'}">{pv_state}</span></div>
    </div>
    <div class="sourceCard">
      {f'<img src="{grid_icon}" alt="GRID">' if grid_icon else ''}
      <div><h3>GRID</h3><span class="state {'on' if grid_state == 'ATIVO' else 'off'}">{grid_state}</span></div>
    </div>
  </section>
  <section class="panel" style="margin-bottom:18px;"><h2>Fonte da ultima execucao</h2><b>{latest_source}</b></section>

  <section class="grid">
    <div class="panel"><h2>Irradiância ajustada e potência PV</h2><canvas id="chartSolar" width="900" height="330"></canvas></div>
    <div class="panel"><h2>Energia PV x Rede</h2><canvas id="chartEnergy" width="900" height="330"></canvas></div>
  </section>

  <section class="panel" style="margin-top:18px;">
    <h2>Últimos registros</h2>
    <div class="tablewrap">
      <table>
        <thead><tr><th>Data</th><th>Hora</th><th>Cidade</th><th>Irrad. ajustada</th><th>PV kW</th><th>Job kWh</th><th>PV kWh</th><th>Grid kWh</th><th>CO₂ g</th><th>Fonte</th><th>Arquivo</th></tr></thead>
        <tbody>{''.join(table_rows) if table_rows else '<tr><td colspan="11">Nenhum CSV encontrado em results/.</td></tr>'}</tbody>
      </table>
    </div>
  </section>
  <div class="footer">Este painel é gerado localmente a partir dos arquivos CSV do PV-First. Ele não envia dados para fora do computador.</div>
</main>
<script>
const rows = {data_json};
function num(x) {{ x = Number(x); return isFinite(x) ? x : 0; }}
function lastN(arr, n) {{ return arr.slice(Math.max(0, arr.length-n)); }}
function drawLineChart(id, series) {{
  const canvas = document.getElementById(id); if (!canvas) return;
  const ctx = canvas.getContext('2d');
  const W = canvas.width, H = canvas.height;
  ctx.clearRect(0,0,W,H);
  ctx.fillStyle = '#fbfdff'; ctx.fillRect(0,0,W,H);
  const padL=55, padR=25, padT=26, padB=46;
  const plotW = W-padL-padR, plotH=H-padT-padB;
  const dataRows = lastN(rows, 180);
  ctx.strokeStyle='#dbe6f1'; ctx.lineWidth=1;
  ctx.beginPath(); ctx.moveTo(padL,padT); ctx.lineTo(padL,H-padB); ctx.lineTo(W-padR,H-padB); ctx.stroke();
  ctx.fillStyle='#6a798a'; ctx.font='13px Segoe UI';
  if (dataRows.length === 0) {{
    ctx.fillText('Nenhum dado encontrado em results/.', padL + 16, padT + 35);
    return;
  }}

  // Cada serie usa sua propria escala vertical.
  // Assim a potencia PV em kW nao some quando e desenhada junto com irradiancia em W/m2.
  series.forEach((s, si) => {{
    const vals = dataRows.map(r => num(r[s.key]));
    let maxV = Math.max(1e-12, ...vals);
    let minV = Math.min(0, ...vals);
    if (maxV === minV) maxV = minV + 1;

    ctx.strokeStyle=s.color; ctx.lineWidth=3; ctx.beginPath();
    dataRows.forEach((r,i) => {{
      const x = padL + (dataRows.length<=1 ? plotW/2 : i*(plotW/(dataRows.length-1)));
      const y = padT + plotH - ((num(r[s.key])-minV)/(maxV-minV))*plotH;
      if (i===0) ctx.moveTo(x,y); else ctx.lineTo(x,y);
    }});
    ctx.stroke();

    // Pontos visiveis, principalmente quando existe apenas uma linha no CSV.
    dataRows.forEach((r,i) => {{
      const x = padL + (dataRows.length<=1 ? plotW/2 : i*(plotW/(dataRows.length-1)));
      const y = padT + plotH - ((num(r[s.key])-minV)/(maxV-minV))*plotH;
      ctx.beginPath(); ctx.arc(x,y,3.5,0,Math.PI*2); ctx.fillStyle=s.color; ctx.fill();
    }});

    ctx.fillStyle=s.color; ctx.fillRect(padL+si*250, H-26, 14, 14);
    ctx.fillStyle='#172033'; ctx.font='13px Segoe UI';
    ctx.fillText(s.label, padL+si*250+20, H-14);
    ctx.fillStyle='#6a798a'; ctx.font='11px Segoe UI';
    ctx.fillText('max: ' + maxV.toFixed(4), padL+si*250+20, H-30);
  }});
}}
drawLineChart('chartSolar', [{{key:'irradiance_adjusted_w_m2', label:'Irradiância ajustada W/m²', color:'#08a9e6'}}, {{key:'pv_power_kw', label:'Potência PV kW', color:'#f5b400'}}]);
drawLineChart('chartEnergy', [{{key:'energy_pv_kwh', label:'Energia PV kWh', color:'#08a9e6'}}, {{key:'energy_grid_kwh', label:'Energia rede kWh', color:'#f5b400'}}]);
</script>
</body>
</html>"""


def main():
    DASH_DIR.mkdir(parents=True, exist_ok=True)
    rows = load_rows()
    html = build_html(rows)
    OUT_HTML.write_text(html, encoding="utf-8")
    print(f"Dashboard gerado: {OUT_HTML}")
    print(f"Registros carregados: {len(rows)}")


if __name__ == "__main__":
    main()
