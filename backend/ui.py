"""PRISM UI chrome — theme tokens, page CSS, sidebar toggle, hero banner.

This module owns all visual scaffolding. `app.py` stays focused on
business logic and just calls:

    from ui import apply_page_chrome, render_theme_toggle
    mode = render_theme_toggle()
    apply_page_chrome(mode)

Adding a new design token? Edit ``THEMES``. Tuning the banner animation?
Edit ``SIM_CONFIG`` (consumed by ``hero.html`` via a JSON injection).
Restyling page chrome? Edit ``page.css``.
"""

from __future__ import annotations

import json
from pathlib import Path

import streamlit as st
import streamlit.components.v1 as components


# ---------------------------------------------------------------------------
# Design tokens — single source of truth for both the page CSS and the
# iframe canvas. Fields starting with ``canvas_`` are consumed only by the
# canvas (kept out of the CSS custom-property block via ``_vars_block``).
# ---------------------------------------------------------------------------

THEMES: dict[str, dict[str, str]] = {
    "light": {
        # Page CSS variables — Snowflake-docs-inspired pale blue-white
        # with a very subtle radial wash (stops are intentionally close
        # so the gradient reads almost flat).
        "bg_stop_1":        "#f4f7fb",
        "bg_stop_2":        "#eef2f7",
        "bg_stop_3":        "#e6ebf2",
        "fg":               "#0e1117",
        "toggle_bg":        "rgba(20, 40, 70, 0.04)",
        "toggle_border":    "#dfe5eb",
        "toggle_fg":        "#0e1117",
        "toggle_active_bg": "rgba(20, 40, 70, 0.10)",
        # Glass card (title overlay in the banner).
        "glass_bg":         "rgba(255, 255, 255, 0.78)",
        "glass_border":     "#dfe5eb",
        "glass_shadow":     "rgba(15, 23, 42, 0.06)",
        "glass_sub_fg":     "#5a6473",
        # Iframe canvas (RGB triples + blend mode).
        "canvas_fg":        "14, 17, 23",     # alive walker trail (looks "black")
        "canvas_halo":      "94, 142, 200",
        "canvas_dim":       "140, 150, 165",  # terminated, not in max bin (grey)
        "canvas_highlight": "30, 120, 220",   # terminated, IS the max bin (blue)
        "canvas_blend":     "multiply",
    },
    "dark": {
        # Deep navy ink with a slightly lighter elevated card stop.
        "bg_stop_1":        "#1a2330",
        "bg_stop_2":        "#0f1620",
        "bg_stop_3":        "#0a1018",
        "fg":               "#e6ecf2",
        "toggle_bg":        "rgba(255, 255, 255, 0.04)",
        "toggle_border":    "#243140",
        "toggle_fg":        "#e6ecf2",
        "toggle_active_bg": "rgba(255, 255, 255, 0.10)",
        "glass_bg":         "rgba(26, 35, 48, 0.78)",
        "glass_border":     "#243140",
        "glass_shadow":     "rgba(0, 0, 0, 0.50)",
        "glass_sub_fg":     "#8a95a3",
        "canvas_fg":        "230, 236, 242",   # alive walker trail (white-ish)
        "canvas_halo":      "130, 200, 255",
        "canvas_dim":       "110, 120, 135",
        "canvas_highlight": "100, 180, 255",   # terminated, IS the max bin (light blue)
        "canvas_blend":     "lighter",
    },
}

SIM_CONFIG: dict[str, float | int] = {
    "lifetime_s":      10,       # walker takes 10s from origin to right edge
    "max_particles":   24,       # slot pool: target_alive + fading terminated
    "trail_subsample": 2,
    "trail_cap":       1000,     # covers a 30s lifetime at every-other-frame sampling
    "num_bins":        11,
    "hist_decay":      0.9985,
    "hist_frac":       0.0555,
    "wave_amp_min":    20,       # post-prism sine/cos amplitude bounds (px)
    "wave_amp_max":    120,      # clamped at runtime to (card_height/2)*0.85
    "wave_freq_min":   0.008,    # radians per pixel
    "wave_freq_max":   0.030,
    "wave_fade_px":    60,       # smoothstep distance for wave to ramp from 0
    "wave_band_frac":  0.85,     # how much of card-half-height waves may use
    "wave_taper_floor": 0.30,    # min amplitude factor near the right edge
    # ---- Lifecycle ----
    "target_alive":    11,       # exactly N walkers in flight at any instant
    "term_fade_s":     4,        # terminated walkers stay visible this long
}

BANNER_HEIGHT = 240

# Browser-side assets live in <project_root>/frontend/. backend/ui.py
# sits one level below the project root, so frontend/ is a sibling.
_FRONTEND_DIR = Path(__file__).resolve().parent.parent / "frontend"
_HERO_PATH    = _FRONTEND_DIR / "hero.html"
_CSS_PATH     = _FRONTEND_DIR / "page.css"


# ---------------------------------------------------------------------------
# Internals.
# ---------------------------------------------------------------------------

def _vars_block(theme: dict[str, str]) -> str:
    """CSS custom-property declarations for one theme (excludes canvas-only fields)."""
    return "\n  ".join(
        f"--{k.replace('_', '-')}: {v};"
        for k, v in theme.items()
        if not k.startswith("canvas_")
    )


@st.cache_data(show_spinner=False)
def _read_text_by_mtime(path_str: str, _mtime_ns: int) -> str:
    """Cache file contents keyed on (path, mtime). Edits invalidate the cache."""
    return Path(path_str).read_text(encoding="utf-8")


def _read_template(path: Path) -> str:
    return _read_text_by_mtime(str(path), path.stat().st_mtime_ns)


def _escape_for_script(payload: str) -> str:
    """Defang `</script>` and `</style>` inside JSON so the embedding tag
    can't be closed early by a stray substring in a value."""
    return payload.replace("</", "<\\/")


# ---------------------------------------------------------------------------
# Public API.
# ---------------------------------------------------------------------------

def render_theme_toggle() -> str:
    """Render the sun/moon toggle in the sidebar; return ``'Light'`` or ``'Dark'``.

    The toggle lives inside a keyed ``st.container`` (CSS class
    ``st-key-prism_theme_block``) so the bottom-of-sidebar pinning rule in
    page.css applies *only* to this block — any sidebar widgets added by
    business logic above stay in normal flow.

    Implementation note: this is a single-button toggle (always the same
    widget key). When clicked we flip ``st.session_state`` and immediately
    ``st.rerun()`` so the icon, page CSS, and iframe theme stay in sync on
    the same frame — otherwise the rendered button icon would lag the
    state by one rerun because the IF-branch deciding which icon to draw
    is evaluated *before* the click is processed.
    """
    if "prism_is_dark" not in st.session_state:
        st.session_state.prism_is_dark = True   # default to dark

    with st.sidebar, st.container(key="prism_theme_block"):
        # Unicode glyphs (☀ / 🌙) render from the OS font so the page has
        # no Google-Fonts CDN dependency at runtime.
        is_dark = st.session_state.prism_is_dark
        glyph   = "🌙" if is_dark else "☀"
        tooltip = "Switch to light theme" if is_dark else "Switch to dark theme"
        if st.button(
            glyph,
            key="prism_theme_toggle",
            type="tertiary",
            help=tooltip,
        ):
            st.session_state.prism_is_dark = not is_dark
            st.rerun()

    return "Dark" if st.session_state.prism_is_dark else "Light"


def apply_page_chrome(mode: str) -> None:
    """Inject the page-wide CSS and render the animated hero banner.

    ``mode`` is ``'Light'`` or ``'Dark'`` (case-insensitive).
    """
    theme_key = mode.lower()
    if theme_key not in THEMES:
        raise ValueError(f"unknown theme {mode!r}; expected one of {list(THEMES)}")

    css = _read_template(_CSS_PATH).replace(
        "__VARS__", _vars_block(THEMES[theme_key]),
    )
    st.markdown(f"<style>{css}</style>", unsafe_allow_html=True)

    payload = _escape_for_script(json.dumps(
        {"mode": theme_key, "themes": THEMES, "sim": SIM_CONFIG},
        separators=(",", ":"),
    ))
    inject = f"<script>window.PRISM_CONFIG = {payload};</script>"
    html = _read_template(_HERO_PATH).replace(
        "<!--PRISM_CONFIG_INJECT-->", inject,
    )
    components.html(html, height=BANNER_HEIGHT, scrolling=False)


__all__ = [
    "THEMES",
    "SIM_CONFIG",
    "BANNER_HEIGHT",
    "apply_page_chrome",
    "render_theme_toggle",
]
