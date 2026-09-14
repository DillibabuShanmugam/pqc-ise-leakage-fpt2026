#!/bin/bash
# Regenerates every number of the paper from the stored traces:
# per-domain fixed-versus-random peaks, the four controls, the cross-domain
# correlation, the paper tables and figures.
set -e
cd "$(dirname "$0")"
python3 tvla_simple.py sim
python3 tvla_simple.py board --pass 1
python3 tvla_simple.py board --pass 2
python3 tvla_controls.py --pass 1
python3 tvla_crossdomain.py --pass 1
python3 tvla_crossdomain.py --pass 2
cp tvla_simple_tvla3_*.json tvla_crossdomain_tvla3_pass*.json ../results/
cd ../../paper && python3 make_scrub_assets.py && python3 make_tvla_figs.py && python3 make_prot_fig.py
