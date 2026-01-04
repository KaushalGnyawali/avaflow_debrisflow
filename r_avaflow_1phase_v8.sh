#!/bin/bash
# 1-PHASE FLOW SIMULATION WITH VOLUME SCALING FLOW TYPE SELECTION (r.avaflow 4.0G)
# Runs single-phase Voellmy model with 4 calibrated flow types (streamflow to
# debris flow) and volume scaling. Uses coarse-to-fine workflow: (1) 5m coarse
# simulation, (2) extract flow footprint, (3) clip 1m fine DEM, (4) fine simulation.
# Outputs profile plots and ParaView/R visualizations for fine run only.

set -e

# =============================================================================
# FLOW TYPE SELECTION
# =============================================================================
# FLOW TYPES (based on sediment concentration):
#   1 = Streamflow         (~5% sediment)   - very fast, long runout
#   2 = Hyperconcentrated  (20-40% sediment) - fast, long runout
#   3 = Mudflow            (40-55% sediment) - moderate
#   4 = Debris flow        (55-70% sediment) - slower, shorter runout

FLOW_TYPE=2              # Hyperconcentrated - good starting point
VOLUME_MULTIPLIER=1.0    # Multiply discharge to increase total volume

# --------------------
# INPUTS (relative to current directory)
# --------------------
BASE_DIR="$(pwd)"
DATA_DIR="${BASE_DIR}/DATA"

DTM_COARSE="${DATA_DIR}/dtm_5m.tif"
DTM_FINE="${DATA_DIR}/dtm_1m.tif"
HYDROGRAPH_ORIGINAL="${DATA_DIR}/hydrograph.txt"
HYDROGRAPH_SCALED="${DATA_DIR}/hydrograph_scaled.txt"
HYDROCOORDS="320930.42,5541572.65,20,-9999"
PROFILE="320930.43,5541572.55,320944.66,5541574.26,320970.22,5541567.79,321011.85,5541553.47,321046.87,5541554.30,321080.66,5541561.26,321100.14,5541578.04,321127.24,5541602.49,321146.06,5541597.91,321168.49,5541594.99,321412.80,5541732.20"

HMAX_ASC="${BASE_DIR}/wc_1phase_coarse_results/wc_1phase_coarse_ascii/wc_1phase_coarse_hflow_max.asc"

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


# =============================================================================
# SET RHEOLOGY BY FLOW TYPE (RHEOLOGICAL PARAMETERS - DO NOT MODIFY LOGIC)
# =============================================================================
# Friction format for 1-phase model: "phi,delta,-xi"
#   phi:   Internal friction angle (degrees)
#   delta: Basal friction angle (degrees) - LOWER = longer runout
#   xi:    Turbulent friction coefficient (m/s²) - HIGHER = longer runout
#          Must be NEGATIVE in friction string to indicate Voellmy turbulent friction

case $FLOW_TYPE in
    1)
        FLOW_NAME="Streamflow (~5% sediment)"
        DENSITY=1050
        PHI=25
        DELTA=2       # Very low basal friction
        XI=2000       # Very high turbulent coeff
        ;;
    2)
        FLOW_NAME="Hyperconcentrated (20-40% sediment)"
        DENSITY=1400
        PHI=28
        DELTA=4       # Low basal friction
        XI=1000       # High turbulent coeff
        ;;
    3)
        FLOW_NAME="Mudflow (40-55% sediment)"
        DENSITY=1600
        PHI=30
        DELTA=6       # Moderate basal friction
        XI=600        # Moderate turbulent coeff
        ;;
    4)
        FLOW_NAME="Debris flow (55-70% sediment)"
        DENSITY=1800
        PHI=32
        DELTA=10      # Higher basal friction
        XI=400        # Lower turbulent coeff
        ;;
    *)
        echo "ERROR: FLOW_TYPE must be 1-4"; exit 1
        ;;
esac

FRICTION="$PHI,$DELTA,-$XI"

# =============================================================================
# SCALE HYDROGRAPH (VOLUME SCALING - DO NOT MODIFY LOGIC)
# =============================================================================
echo "=============================================="
echo "SCALING HYDROGRAPH"
echo "=============================================="

python3 << EOF
import sys

multiplier = $VOLUME_MULTIPLIER
input_file = "$HYDROGRAPH_ORIGINAL"
output_file = "$HYDROGRAPH_SCALED"

total_q_original = 0
total_q_scaled = 0

with open(input_file, 'r') as fin, open(output_file, 'w') as fout:
    header = fin.readline()
    fout.write(header)
    
    prev_t = 0
    for line in fin:
        parts = line.strip().split()
        if len(parts) >= 3:
            t = float(parts[0])
            q = float(parts[1])
            v = float(parts[2])
            
            # Scale discharge
            q_scaled = q * multiplier
            
            # Accumulate for volume calculation
            dt = t - prev_t
            total_q_original += q * dt
            total_q_scaled += q_scaled * dt
            prev_t = t
            
            fout.write(f"{t:.0f}\t{q_scaled:.2f}\t{v:.1f}\n")

print(f"Original volume:  {total_q_original:,.0f} m³")
print(f"Scaled volume:    {total_q_scaled:,.0f} m³")
print(f"Scale factor:     {multiplier:.1f}x")
print(f"Output: {output_file}")
EOF

echo ""
echo "=============================================="
echo "FLOW TYPE $FLOW_TYPE: $FLOW_NAME"
echo "=============================================="
echo "Rheological parameters:"
echo "  Density:    $DENSITY kg/m³"
echo "  phi:        $PHI° (internal friction)"
echo "  delta:      $DELTA° (basal friction)"
echo "  xi:         $XI m/s² (turbulent coeff)"
echo "Friction string: $FRICTION"
echo ""

# --------------------
# 1) COARSE RUN
# --------------------
echo "=== STEP 1: Coarse simulation (${CELL_COARSE}m) ==="

r.in.gdal -o --overwrite input="$DTM_COARSE" output=dtm_coarse
g.region raster=dtm_coarse -a

echo "Cells: $(g.region -p | grep cells | awk '{print $2}')"

r.avaflow.40G -e -v \
    prefix="wc_1phase_coarse" \
    cellsize="$CELL_COARSE" \
    phases=1 \
    density="$DENSITY" \
    elevation=dtm_coarse \
    friction="$FRICTION" \
    cstopping="$CSTOPPING" \
    time="$TIME" \
    hydrocoords="$HYDROCOORDS" \
    hydrograph="$HYDROGRAPH_SCALED" \
    thresholds="$THRESHOLDS" \
    visualization="$VISUALIZATION_COARSE" \
    cfl="$CFL"

# --------------------
# 2) BUILD CLIP MASK AT COARSE RESOLUTION
# --------------------
echo ""
echo "=== STEP 2: Create flow mask ==="

r.in.gdal -o --overwrite input="$HMAX_ASC" output=hflow_max_coarse

r.mapcalc --overwrite "mask_coarse_raw = if(hflow_max_coarse > $FLOW_THRESH, 1, null())"
r.grow input=mask_coarse_raw output=mask_coarse radius=$BUFFER_CELLS --overwrite

g.region zoom=mask_coarse align=dtm_coarse -a

# --------------------
# 3) CLIP FINE DEM (1 m resolution)
# --------------------
echo ""
echo "=== STEP 3: Clip fine DEM (${CELL_FINE}m) ==="

g.region res=$CELL_FINE -a

echo "Cells: $(g.region -p | grep cells | awk '{print $2}')"

r.in.gdal -o --overwrite input="$DTM_FINE" output=dtm_fine_full

r.mask --overwrite raster=mask_coarse
r.mapcalc --overwrite "dtm_fine_clip = dtm_fine_full"
r.mask -r

g.region raster=dtm_fine_clip -a

# --------------------
# 4) FINE RUN (with profile and visualization outputs)
# --------------------
echo ""
echo "=== STEP 4: Fine simulation (${CELL_FINE}m) ==="

r.avaflow.40G -e -v \
    prefix="wc_1phase_fine" \
    cellsize="$CELL_FINE" \
    phases=1 \
    density="$DENSITY" \
    elevation=dtm_fine_clip \
    friction="$FRICTION" \
    cstopping="$CSTOPPING" \
    time="$TIME" \
    hydrocoords="$HYDROCOORDS" \
    hydrograph="$HYDROGRAPH_SCALED" \
    profile="$PROFILE" \
    thresholds="$THRESHOLDS" \
    visualization="$VISUALIZATION_FINE" \
    cfl="$CFL"

echo ""
echo "=============================================="
echo "COMPLETE"
echo "=============================================="
echo "Flow type: $FLOW_NAME"
echo "Volume multiplier: ${VOLUME_MULTIPLIER}x"
echo ""
echo "If runout is too short:"
echo "  → Increase VOLUME_MULTIPLIER"
echo "  → Or decrease FLOW_TYPE (lower = longer runout)"
echo ""
echo "If runout is too long:"
echo "  → Decrease VOLUME_MULTIPLIER"
echo "  → Or increase FLOW_TYPE (higher = shorter runout)"
