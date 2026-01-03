#!/bin/bash
#
# Single-Phase r.avaflow - Coarse (5m) to Fine (1m) Workflow
# ----------------------------------------------------------
#
# Resolution:
#   Coarse: 5 m (fast, defines flow footprint)
#   Fine:   1 m (detailed, clipped to footprint)
#
# No GPU - CPU only.
#

set -e

# =============================================================================
# FLOW CLASS
# =============================================================================
FLOW_CLASS=3    # 1=streamflow, 2=hyperconcentrated, 3=debris flow, 4=landslide

# =============================================================================
# INPUT FILES
# =============================================================================
DTM_COARSE="/home/kaushal/Desktop/Projects/Wilson_Creek_v2/DATA/dtm_5m.tif"
DTM_FINE="/home/kaushal/Desktop/Projects/Wilson_Creek_v2/DATA/dtm_1m.tif"
HYDROGRAPH="/home/kaushal/Desktop/Projects/Wilson_Creek_v2/DATA/hydrograph.txt"

HMAX_COARSE="/home/kaushal/Desktop/Projects/Wilson_Creek_v2/wc_1phase_coarse_results/wc_1phase_coarse_ascii/wc_1phase_coarse_hflow_max.asc"

# =============================================================================
# RESOLUTION
# =============================================================================
CELL_COARSE=5
CELL_FINE=1      # Changed from 0.5 to 1 m

# =============================================================================
# CLIPPING PARAMETERS
# =============================================================================
FLOW_THRESH=0.01
BUFFER_CELLS=10  # 10 × 5 m = 50 m buffer

# =============================================================================
# SIMULATION PARAMETERS
# =============================================================================
HYDROCOORDS="320930.42,5541572.65,20,-9999"
TIME="100,600"

CFL_COARSE="0.50,0.005"
CFL_FINE="0.50,0.005"    # Can be same as coarse at 1 m resolution

CSTOPPING=1              # Stop when flow stops
OUTPUT_INTERVAL=5.0      # Write every 5 s

COHESION=0.0
VISCOSITY=-7.0
THRESHOLDS="0.1,10000,10000,1.0,0.000001"
VISUALIZATION="0,$OUTPUT_INTERVAL,5.0,5.0,1,100,2,-11000,9000,100,0.60,0.25,0.15,0.2,1.0,None,None,None"

# =============================================================================
# SET PARAMETERS BY FLOW CLASS
# =============================================================================
case $FLOW_CLASS in
    1) CLASS_NAME="Streamflow";        DENSITY=1100; DELTA=5;  XI=1500 ;;
    2) CLASS_NAME="Hyperconcentrated"; DENSITY=1500; DELTA=12; XI=600  ;;
    3) CLASS_NAME="Debris flow";       DENSITY=1800; DELTA=20; XI=300  ;;
    4) CLASS_NAME="Landslide";         DENSITY=2100; DELTA=30; XI=150  ;;
    *) echo "ERROR: FLOW_CLASS must be 1-4"; exit 1 ;;
esac

FRICTION="$DELTA,$XI,0.0"

echo "=============================================="
echo "FLOW CLASS $FLOW_CLASS: $CLASS_NAME"
echo "=============================================="
echo "Density: $DENSITY kg/m³ | δ: $DELTA° | ξ: $XI m/s²"
echo "Coarse: ${CELL_COARSE}m | Fine: ${CELL_FINE}m"
echo ""

# =============================================================================
# STEP 1: COARSE SIMULATION
# =============================================================================
echo "=== STEP 1: Coarse simulation (${CELL_COARSE}m) ==="

r.in.gdal -o --overwrite input="$DTM_COARSE" output=dtm_coarse
g.region raster=dtm_coarse -a

echo "Region: $(g.region -p | grep cells | awk '{print $2}') cells"

r.avaflow.40G -e -v \
    prefix="wc_1phase_coarse" \
    cellsize="$CELL_COARSE" \
    phases=1 \
    density="$DENSITY" \
    elevation=dtm_coarse \
    friction="$FRICTION" \
    cohesion="$COHESION" \
    viscosity="$VISCOSITY" \
    cstopping="$CSTOPPING" \
    time="$TIME" \
    hydrocoords="$HYDROCOORDS" \
    hydrograph="$HYDROGRAPH" \
    thresholds="$THRESHOLDS" \
    visualization="$VISUALIZATION" \
    cfl="$CFL_COARSE"

# =============================================================================
# STEP 2: CREATE FLOW MASK
# =============================================================================
echo ""
echo "=== STEP 2: Create flow mask ==="

r.in.gdal -o --overwrite input="$HMAX_COARSE" output=hflow_max_coarse
r.mapcalc --overwrite "flow_mask_raw = if(hflow_max_coarse > $FLOW_THRESH, 1, null())"
r.grow input=flow_mask_raw output=flow_mask radius=$BUFFER_CELLS --overwrite

# =============================================================================
# STEP 3: CLIP FINE DEM
# =============================================================================
echo ""
echo "=== STEP 3: Clip fine DEM (${CELL_FINE}m) ==="

g.region zoom=flow_mask align=dtm_coarse -a
g.region res=$CELL_FINE -a

echo "Clipped region: $(g.region -p | grep cells | awk '{print $2}') cells"

r.in.gdal -o --overwrite input="$DTM_FINE" output=dtm_fine_full

r.mask --overwrite raster=flow_mask
r.mapcalc --overwrite "dtm_fine_clip = dtm_fine_full"
r.mask -r

g.region raster=dtm_fine_clip -a

# =============================================================================
# STEP 4: FINE SIMULATION
# =============================================================================
echo ""
echo "=== STEP 4: Fine simulation (${CELL_FINE}m) ==="

r.avaflow.40G -e -v \
    prefix="wc_1phase_fine" \
    cellsize="$CELL_FINE" \
    phases=1 \
    density="$DENSITY" \
    elevation=dtm_fine_clip \
    friction="$FRICTION" \
    cohesion="$COHESION" \
    viscosity="$VISCOSITY" \
    cstopping="$CSTOPPING" \
    time="$TIME" \
    hydrocoords="$HYDROCOORDS" \
    hydrograph="$HYDROGRAPH" \
    thresholds="$THRESHOLDS" \
    visualization="$VISUALIZATION" \
    cfl="$CFL_FINE"

echo ""
echo "=============================================="
echo "Complete: $CLASS_NAME (${CELL_FINE}m resolution)"
echo "=============================================="
