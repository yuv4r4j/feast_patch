"""PRISM — Streamlit application entry point.

Run from the project root:

    streamlit run app.py

Visual chrome (theme tokens, sun/moon toggle, page CSS, animated PRISM
banner) lives in ``backend/ui.py`` and ``frontend/page.css``. Sidebar
layout + parameter inputs live in ``backend/sidebar.py``. Tuning the
banner animation goes in ``backend.ui.SIM_CONFIG``; adding a sidebar
parameter goes in ``backend.sidebar.FEE_SPECS``.

This file should stay focused on wiring + business logic.
"""

from __future__ import annotations

import streamlit as st

from backend.main import render_main
from backend.sidebar import render_sidebar
from backend.ui import apply_page_chrome, render_theme_toggle


st.set_page_config(
    page_title="PRISM",
    layout="wide",
    initial_sidebar_state="expanded",
)


# ---------------------------------------------------------------------------
# Page chrome + sidebar.
# ---------------------------------------------------------------------------

mode = render_theme_toggle()
apply_page_chrome(mode)

# Main-page widgets render directly below the hero banner.
main = render_main()
# Sidebar fee inputs (rendered into st.sidebar — order doesn't matter
# visually, but keep it after the chrome so the bottom-pinned toggle
# CSS has already attached).
fees = render_sidebar()


# ---------------------------------------------------------------------------
# Inputs — captured into named variables for downstream use.
# ---------------------------------------------------------------------------
# `fees` is a frozen `FeeInputs`  dataclass (backend/sidebar.py).
# `main` is a frozen `MainInputs` dataclass (backend/main.py).
# All values are also in st.session_state under their key names.

late_fee_first     = fees.late_fee_first
late_fee_multiple  = fees.late_fee_multiple
CP_per_100         = fees.CP_per_100
BT_fee             = fees.BT_fee
fee_cash_advance   = fees.fee_cash_advance
dc_fee             = fees.dc_fee

print(late_fee_first, late_fee_multiple, CP_per_100, BT_fee, fee_cash_advance, dc_fee)

actuals_start_date = main.actuals_start_date
actuals_end_date   = main.actuals_end_date
actuals_date_range = main.actuals_date_range   # convenience tuple (start, end)
months_to_add      = main.months_to_add        # int, months past actuals_end_date
bad_months         = main.bad_months            # date, "bad months" reference


# ---------------------------------------------------------------------------
# Business logic
# ---------------------------------------------------------------------------
# Use the named variables above to drive the Monte-Carlo simulation,
# plots, tables, etc.
