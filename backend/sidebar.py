"""PRISM sidebar — description copy + Monte-Carlo fee inputs.

This module owns the *content* of the sidebar (description, parameter
widgets). The bottom-pinned theme toggle and page chrome live in
``ui.py``; this module assumes that ``ui.render_theme_toggle()`` has
already been invoked elsewhere so the toggle container exists.

Design notes
------------
- Numeric fee inputs are declared as frozen ``NumericParamSpec`` instances
  in ``FEE_SPECS``. Adding or removing a fee field is a one-line edit
  there — and a matching field on ``FeeInputs`` so the typed return
  shape stays in sync.
- ``render_sidebar()`` returns a frozen ``FeeInputs`` dataclass so callers
  get attribute access (``fees.late_fee_first``) with IDE autocomplete +
  type-checker support. The same values are also written into
  ``st.session_state`` under identical keys.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Sequence

import streamlit as st


# ---------------------------------------------------------------------------
# Parameter specs.
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class NumericParamSpec:
    """Declarative spec for a ``st.number_input`` widget.

    ``key`` is used as both the display label and the ``st.session_state``
    key, so downstream code can read the live value via
    ``st.session_state[spec.key]``.
    """

    key: str
    default: float
    step: float
    min_value: float = 0.0
    max_value: float = 1_000.0
    fmt: str = "%.2f"
    help: str | None = None


# Past-vintage fee model inputs. Add / remove / reorder rows here to
# change the sidebar — and add the matching field on ``FeeInputs`` below
# so the typed return shape stays in sync.
FEE_SPECS: Sequence[NumericParamSpec] = (
    NumericParamSpec("late_fee_first",    29.00, 1.00, max_value=1_000.0),
    NumericParamSpec("late_fee_multiple", 39.00, 1.00, max_value=1_000.0),
    NumericParamSpec("CP_per_100",         0.96, 0.01, max_value=10.0),
    NumericParamSpec("BT_fee",             0.05, 0.01, max_value=1.0),
    NumericParamSpec("fee_cash_advance",   0.08, 0.01, max_value=1.0),
    NumericParamSpec("dc_fee",             4.95, 0.05, max_value=1_000.0),
)


@dataclass(frozen=True)
class FeeInputs:
    """Snapshot of the sidebar fee values returned by ``render_sidebar``.

    Attribute names match ``FEE_SPECS`` keys one-to-one so callers can use
    attribute access (``fees.late_fee_first``) — clearer than dict
    indexing, with IDE autocomplete + static-type-checker coverage.
    """

    late_fee_first:    float
    late_fee_multiple: float
    CP_per_100:        float
    BT_fee:            float
    fee_cash_advance:  float
    dc_fee:            float


# ---------------------------------------------------------------------------
# Static copy.
# ---------------------------------------------------------------------------

_DESCRIPTION = """
PRISM is a Monte-Carlo simulation framework for quantifying uncertainty
in stochastic systems. It propagates probabilistic inputs through a
user-defined model and aggregates the outcomes into an empirical
distribution — surfacing **risk**, **sensitivity**, and **confidence
intervals** at a glance.

"""

_FEES_HEADING_HTML = (
    "<p style='text-align:center; font-weight:700; margin:0 0 1rem 0;'>"
    "Past Vintages Inputs</p>"
)


# ---------------------------------------------------------------------------
# Public API.
# ---------------------------------------------------------------------------

def render_sidebar() -> FeeInputs:
    """Render the sidebar; return current fee values as a typed snapshot.

    Side effects: widget values are also written to ``st.session_state``
    under their key names, so callers may read from either source.

    The fee inputs are wrapped in a keyed container so page.css can style
    the group as a frosted-glass panel via ``.st-key-prism_fees_block``.
    """
    with st.sidebar:
        # Description in its own glass panel.
        with st.container(key="prism_description_block"):
            st.markdown(_DESCRIPTION)
        # Line spacer between the two glass panels.
        st.divider()
        # Fee inputs in a matching glass panel.
        with st.container(key="prism_fees_block"):
            st.markdown(_FEES_HEADING_HTML, unsafe_allow_html=True)
            values = {spec.key: _numeric_input(spec) for spec in FEE_SPECS}
            # Empty trailing line — gives breathing room inside the glass
            # panel between the last input and the bottom border.
            st.markdown("&nbsp;", unsafe_allow_html=True)
    return FeeInputs(**values)


# ---------------------------------------------------------------------------
# Internals.
# ---------------------------------------------------------------------------

def _numeric_input(spec: NumericParamSpec) -> float:
    """Render one ``st.number_input`` from a ``NumericParamSpec``."""
    return st.number_input(
        spec.key,
        min_value=spec.min_value,
        max_value=spec.max_value,
        value=spec.default,
        step=spec.step,
        format=spec.fmt,
        key=spec.key,
        help=spec.help,
    )


__all__ = ["FEE_SPECS", "FeeInputs", "NumericParamSpec", "render_sidebar"]
