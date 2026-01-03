#!/bin/bash
#
# Single-Phase r.avaflow with Volume Scaling
# -------------------------------------------
# FLOW TYPES (based on sediment concentration):
#   1 = Streamflow         (~5% sediment)   - very fast, long runout
#   2 = Hyperconcentrated  (20-40% sediment) - fast, long runout
#   3 = Mudflow            (40-55% sediment) - moderate
#   4 = Debris flow        (55-70% sediment) - slower, shorter runout
#

set -e

# =============================================================================
# USER SETTINGS - MODIFY THESE
# =============================================================================

# Volume multiplier: multiply discharge to increase total volume. Default =1.0
VOLUME_MULTIPLIER=1.0

# Flow type (1-4)
FLOW_TYPE=2  # Hyperconcentrated - good starting point

# =============================================================================
# INPUT FILES
# =============================================================================
DTM_COARSE="/home/kaushal/Desktop/Projects/Wilson_Creek_v2/DATA/dtm_5m.tif"
DTM_FINE="/home/kaushal/Desktop/Projects/Wilson_Creek_v2/DATA/dtm_1m.tif"
HYDROGRAPH_ORIGINAL="/home/kaushal/Desktop/Projects/Wilson_Creek_v2/DATA/hydrograph.txt"
HYDROGRAPH_SCALED="/home/kaushal/Desktop/Projects/Wilson_Creek_v2/DATA/hydrograph_scaled.txt"

HMAX_COARSE="/home/kaushal/Desktop/Projects/Wilson_Creek_v2/wc_1phase_coarse_results/wc_1phase_coarse_ascii/wc_1phase_coarse_hflow_max.asc"

# =============================================================================
# RESOLUTION
# =============================================================================
CELL_COARSE=5
CELL_FINE=1

# =============================================================================
# SIMULATION PARAMETERS
# =============================================================================
HYDROCOORDS="320930.42,5541572.65,20,-9999"
TIME="50,700"
CFL="0.50,0.005"

FLOW_THRESH=0.005
BUFFER_CELLS=20

CSTOPPING=1
OUTPUT_INTERVAL=10.0

THRESHOLDS="0.1,10000,10000,1.0,0.000001"
VISUALIZATION="0,$OUTPUT_INTERVAL,5.0,5.0,1,100,2,-11000,9000,100,0.60,0.25,0.15,0.2,1.0,None,None,None"

# =============================================================================
# SET RHEOLOGY BY FLOW TYPE
# =============================================================================
# Parameters calibrated for equivalent runout to 3-phase model
#
# Friction format: "phi,delta,-xi"
#   phi:   Internal friction (degrees)
#   delta: Basal friction (degrees) - LOWER = longer runout
#   xi:    Turbulent coeff (m/s²) - HIGHER = longer runout
#         Must be NEGATIVE for Voellmy model

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
# SCALE HYDROGRAPH
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
echo ""
echo "Rheological parameters:"
echo "  Density:    $DENSITY kg/m³"
echo "  phi:        $PHI° (internal friction)"
echo "  delta:      $DELTA° (basal friction)"
echo "  xi:         $XI m/s² (turbulent coeff)"
echo ""
echo "Friction string: $FRICTION"
echo ""

# =============================================================================
# STEP 1: COARSE SIMULATION
# =============================================================================
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
    visualization="$VISUALIZATION" \
    cfl="$CFL"

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

echo "Cells: $(g.region -p | grep cells | awk '{print $2}')"

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
    cstopping="$CSTOPPING" \
    time="$TIME" \
    hydrocoords="$HYDROCOORDS" \
    hydrograph="$HYDROGRAPH_SCALED" \
    thresholds="$THRESHOLDS" \
    visualization="$VISUALIZATION" \
    cfl="$CFL"

echo ""
echo "=============================================="
echo "COMPLETE"
echo "=============================================="
echo "Flow type: $FLOW_NAME"
echo "Volume multiplier: ${VOLUME_MULTIPLIER}x"
echo ""
echo "If runout is still too short:"
echo "  → Increase VOLUME_MULTIPLIER"
echo "  → Or decrease FLOW_TYPE (lower = longer runout)"
echo ""
echo "If runout is too long:"
echo "  → Decrease VOLUME_MULTIPLIER"
echo "  → Or increase FLOW_TYPE (higher = shorter runout)"
