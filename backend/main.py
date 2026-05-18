"""PRISM main-page widgets — render content in the main body, below the
animated PRISM banner.

Mirrors the structure of ``backend/sidebar.py``: declarative typed return
shape (``MainInputs``), one ``render_main()`` entry point. Add new
main-page widgets by extending ``MainInputs`` + the render body.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import date, timedelta

import streamlit as st


# ---------------------------------------------------------------------------
# Typed return shape.
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class MainInputs:
    """Snapshot of the main-page widget values returned by ``render_main``.

    Start and end of the actuals window are stored as separate fields
    (matching the two date pickers in the UI). ``actuals_date_range`` is
    a convenience property that bundles them as a ``(start, end)`` tuple.

    ``months_to_add`` is the number of months past ``actuals_end_date``
    that the simulation should project forward. ``bad_months`` is the
    reference date marking the "bad months" cutoff for the model.
    """

    actuals_start_date: date
    actuals_end_date:   date
    months_to_add:      int
    bad_months:         date

    @property
    def actuals_date_range(self) -> tuple[date, date]:
        return (self.actuals_start_date, self.actuals_end_date)


# Forecast-horizon slider bounds.
MONTHS_TO_ADD_MIN     = 1
MONTHS_TO_ADD_MAX     = 60
MONTHS_TO_ADD_DEFAULT = 57


# ---------------------------------------------------------------------------
# Defaults.
# ---------------------------------------------------------------------------

def _default_actuals_range() -> tuple[date, date]:
    """Past 365 days ending today. Recomputed each rerun so "today" is fresh."""
    today = date.today()
    return (today - timedelta(days=365), today)


# ---------------------------------------------------------------------------
# Public API.
# ---------------------------------------------------------------------------

def render_main() -> MainInputs:
    """Render the main-page input widgets; return a typed snapshot.

    Call after ``ui.apply_page_chrome(mode)`` so the widgets appear
    immediately below the PRISM hero banner. Two side-by-side date
    pickers (start + end) bound to ``st.session_state.actuals_start_date``
    and ``st.session_state.actuals_end_date``.
    """
    default_start, default_end = _default_actuals_range()

    # Vertical breathing room between the hero banner and the input row.
    st.write("")

    # All inputs on a single row. Thin sep columns carry a vertical line
    # between logical groupings; the trailing spacer column eats whatever
    # page width is left.
    (
        col_start, col_end,
        col_sep,
        col_slider,
        col_sep2,
        col_bad,
        _spacer,
    ) = st.columns([1, 1, 0.15, 3, 0.15, 1, 4])

    start_date = col_start.date_input(
        "actuals_start_date",
        value=default_start,
        key="actuals_start_date",
    )
    end_date = col_end.date_input(
        "actuals_end_date",
        value=default_end,
        key="actuals_end_date",
    )
    col_sep.markdown(
        '<div class="prism-vsep"></div>',
        unsafe_allow_html=True,
    )
    months_to_add = col_slider.slider(
        "months_to_add",
        min_value=MONTHS_TO_ADD_MIN,
        max_value=MONTHS_TO_ADD_MAX,
        value=MONTHS_TO_ADD_DEFAULT,
        step=1,
        key="months_to_add",
    )
    col_sep2.markdown(
        '<div class="prism-vsep"></div>',
        unsafe_allow_html=True,
    )
    bad_months = col_bad.date_input(
        "bad_months",
        value=date.today(),
        key="bad_months",
    )

    # `st.date_input` with a scalar value returns a single date; guard
    # anyway in case Streamlit ever returns the tuple form on first paint.
    if isinstance(start_date, tuple):
        start_date = start_date[0]
    if isinstance(end_date, tuple):
        end_date = end_date[-1]

    if isinstance(bad_months, tuple):
        bad_months = bad_months[0]

    return MainInputs(
        actuals_start_date=start_date,
        actuals_end_date=end_date,
        months_to_add=int(months_to_add),
        bad_months=bad_months,
    )


__all__ = ["MainInputs", "render_main"]
