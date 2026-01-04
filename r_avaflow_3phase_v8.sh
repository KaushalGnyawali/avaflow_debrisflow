#!/bin/bash
# 3-PHASE DEBRIS FLOW SIMULATION (r.avaflow 4.0G)
# Runs multi-phase flow model (solid, fine, fluid) using computational-efficient
# coarse-to-fine workflow: (1) 5m coarse simulation, (2) extract flow footprint,
# (3) clip 1m fine DEM to flow area only, (4) high-resolution fine simulation.
# Outputs profile plots and ParaView/R visualizations for fine run only.

set -e

# --------------------
# INPUTS
# --------------------
# Get current working directory (project root)
BASE_DIR="$(pwd)"
DATA_DIR="${BASE_DIR}/DATA"

DTM_COARSE="${DATA_DIR}/dtm_5m.tif"
DTM_FINE="${DATA_DIR}/dtm_1m.tif"
HYDROGRAPH="${DATA_DIR}/hydrograph_3phase.txt"
HYDROCOORDS="320930.42,5541572.65,20,-9999"
PROFILE="${DATA_DIR}/profile.txt"

HMAX_ASC="${BASE_DIR}/wc_3phase_coarse_results/wc_3phase_coarse_ascii/wc_3phase_coarse_hflow_max.asc"

# --------------------
# PARAMETERS
# --------------------
CELL_COARSE=5
CELL_FINE=1

# FLOW_THRESH: minimum flow height (m) to include in flow mask
# Value of 0.005 m (5 mm) filters out numerical noise and trivial flow
FLOW_THRESH=0.005

# BUFFER_CELLS: number of cells to expand flow mask beyond computed flow area
# Value of 20 cells provides safety margin to prevent edge effects when switching to fine resolution
BUFFER_CELLS=20

# 3-phase material parameters (UNCHANGED)
PHASES=3
DENSITY="2700,1800,1000"           # solid, fine, fluid (kg/m³)
FRICTION="30,0,0,12,0,0,0,0,0.05"  # phase-specific friction angles and Manning's n

# TIME: "start_output,end_time" (seconds)
# First value (50): Time interval between outputs - results written every 50 seconds
# Second value (700): Simulation end time - stops at 700 seconds
TIME="50,700"

# CFL: "cfl_criterion,alternative_timestep"
# First value (0.50): CFL criterion (≤0.5) - controls adaptive timestep via Courant condition
#   Model computes: dt = CFL × (cell_size / wave_speed)
#   Higher values = faster but less stable; 0.4 is safer default; 0.50 is at upper limit
# Second value (0.005): Alternative timestep (s) used when CFL invalid (e.g., zero velocity at start)
CFL="0.50,0.005"

# Computational controls
CSTOPPING=1

# THRESHOLDS: "hflow_min,vmax,kemax,hflow_ratio,min_threshold"
# Numerical cutoffs and display thresholds:
#   0.1 m = minimum flow height for simulation (prevents instability)
#   10000 m/s = maximum velocity cap
#   10000 J = maximum kinetic energy cap
#   1.0 = flow height ratio threshold
#   0.000001 = minimum threshold for numerical stability
THRESHOLDS="0.05,10000,10000,1.0,0.000001"

# VISUALIZATION: "deform,hflowmin,hflowref,htsunref,hcontmin,hcontmax,hcontint,zcontmin,zcontmax,zcontint,pred,pgreen,pblue,pexp,phexagg,pvpath,rscriptpath,rlibspath"
# Controls display/visualization settings (NOT output timing):
#   deform (0): orthophoto deformation control (0=off, 1=on with destruction, 2=on without)
#   hflowmin (0.1 m): minimum flow height to display
#   hflowref (5.0 m): reference flow height for transparency scaling
#   htsunref (5.0 m): reference tsunami height (if applicable)
#   hcontmin-max-int (1,100,2 m): flow/tsunami height contour levels and interval
#   zcontmin-max-int (-11000,9000,100 m): elevation contour levels and interval
#   pred,pgreen,pblue (0.60,0.25,0.15): RGB color weights for flow visualization
#   pexp (0.2): transparency curve exponent
#   phexagg (1.0): flow height exaggeration factor in profiles
#   pvpath,rscriptpath,rlibspath: paths to external visualization tools

# Coarse run: no external visualization outputs
VISUALIZATION_COARSE="0,0.05,5.0,5.0,1,100,2,-11000,9000,100,0.60,0.25,0.15,0.2,1.0,None,None,None"

# Fine run: enable ParaView and R visualization outputs
VISUALIZATION_FINE="0,0.05,5.0,5.0,1,100,2,-11000,9000,100,0.60,0.25,0.15,0.2,1.0,None,None,None"

# --------------------
# 1) COARSE RUN
# --------------------
r.in.gdal -o --overwrite input="$DTM_COARSE" output=dtm_coarse
g.region raster=dtm_coarse -a

r.avaflow.40G -e -v \
  prefix="wc_3phase_coarse" \
  cellsize="$CELL_COARSE" \
  phases="$PHASES" \
  density="$DENSITY" \
  elevation=dtm_coarse \
  friction="$FRICTION" \
  cstopping="$CSTOPPING" \
  time="$TIME" \
  hydrocoords="$HYDROCOORDS" \
  hydrograph="$HYDROGRAPH" \
  thresholds="$THRESHOLDS" \
  visualization="$VISUALIZATION_COARSE" \
  cfl="$CFL"

# --------------------
# 2) BUILD CLIP MASK AT COARSE RESOLUTION
# --------------------
r.in.gdal -o --overwrite input="$HMAX_ASC" output=hflow_max_coarse

r.mapcalc --overwrite "mask_coarse_raw = if(hflow_max_coarse > $FLOW_THRESH, 1, null())"
r.grow input=mask_coarse_raw output=mask_coarse radius=$BUFFER_CELLS --overwrite

g.region zoom=mask_coarse align=dtm_coarse -a

# --------------------
# 3) CLIP FINE DEM (1 m resolution)
# --------------------
g.region res=$CELL_FINE -a

r.in.gdal -o --overwrite input="$DTM_FINE" output=dtm_fine_full

r.mask --overwrite raster=mask_coarse
r.mapcalc --overwrite "dtm_fine_clip = dtm_fine_full"
r.mask -r

g.region raster=dtm_fine_clip -a

# --------------------
# 4) FINE RUN (with profile and visualization outputs)
# --------------------
r.avaflow.40G -e -v \
  prefix="wc_3phase_fine" \
  cellsize="$CELL_FINE" \
  phases="$PHASES" \
  density="$DENSITY" \
  elevation=dtm_fine_clip \
  friction="$FRICTION" \
  cstopping="$CSTOPPING" \
  time="$TIME" \
  hydrocoords="$HYDROCOORDS" \
  hydrograph="$HYDROGRAPH" \
  profile="$PROFILE" \
  thresholds="$THRESHOLDS" \
  visualization="$VISUALIZATION_FINE" \
  cfl="$CFL"

echo "Done. 3-phase simulation complete at 1 m resolution with profile and visualization outputs."
