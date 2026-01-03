#!/bin/bash
# Crash-proof coarse → clip → fine r.avaflow workflow

set -e

# --------------------
# INPUTS
# --------------------
DTM_5M="/home/kaushal/Desktop/Projects/Wilson_Creek_v2/DATA/dtm_5m.tif"
DTM_05M="/home/kaushal/Desktop/Projects/Wilson_Creek_v2/DATA/dtm_0pt5m.tif"
HYDROGRAPH="/home/kaushal/Desktop/Projects/Wilson_Creek_v2/DATA/hydrograph_3phase.txt"
HYDROCOORDS="320930.42,5541572.65,20,-9999"

HMAX_ASC="/home/kaushal/Desktop/Projects/Wilson_Creek_v2/wc_coarse_results/wc_coarse_ascii/wc_coarse_hflow_max.asc"

# --------------------
# PARAMETERS
# --------------------
CELL_COARSE=5
CELL_FINE=0.5
FLOW_THRESH=0.005

PHASES=3
DENSITY="2700,1800,1000"
FRICTION="30,0,0,12,0,0,0,0,0.05"
TIME="100,600"
CFL="0.40,0.001"

# --------------------
# 1) COARSE RUN
# --------------------
r.in.gdal -o --overwrite input="$DTM_5M" output=dtm_5m
g.region raster=dtm_5m -a

r.avaflow.40G \
  prefix="wc_coarse" \
  cellsize="$CELL_COARSE" \
  phases="$PHASES" \
  density="$DENSITY" \
  elevation=dtm_5m \
  friction="$FRICTION" \
  time="$TIME" \
  hydrocoords="$HYDROCOORDS" \
  hydrograph="$HYDROGRAPH" \
  cfl="$CFL"

# --------------------
# 2) BUILD CLIP MASK AT COARSE RESOLUTION (SAFE)
# --------------------
r.in.gdal -o --overwrite input="$HMAX_ASC" output=hflow_max_5m

# Threshold at 5 m (cheap)
r.mapcalc --overwrite "mask_5m = if(hflow_max_5m > $FLOW_THRESH, 1, null())"

# Shrink region NOW (this is the critical fix)
g.region zoom=mask_5m align=dtm_5m -a

# --------------------
# 3) CLIP FINE DEM USING SMALL REGION
# --------------------
r.in.gdal -o --overwrite input="$DTM_05M" output=dtm_05m_full

# Region is already small; resolution switches to 0.5 m automatically
g.region res=$CELL_FINE -a

r.mask --overwrite raster=mask_5m
r.mapcalc --overwrite "dtm_05m_clip = dtm_05m_full"
r.mask -r

# Force region = clipped DEM (mandatory)
g.region raster=dtm_05m_clip -a

# --------------------
# 4) FINE RUN
# --------------------
r.avaflow.40G \
  prefix="wc_fine" \
  cellsize="$CELL_FINE" \
  phases="$PHASES" \
  density="$DENSITY" \
  elevation=dtm_05m_clip \
  friction="$FRICTION" \
  time="$TIME" \
  hydrocoords="$HYDROCOORDS" \
  hydrograph="$HYDROGRAPH" \
  cfl="$CFL"

echo "Done. No fine-resolution raster processing outside clipped region."

