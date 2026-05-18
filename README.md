# prsim

A self-contained Streamlit app: animated PRISM hero banner + sun/moon
theme toggle + sidebar parameter inputs, ready for business logic in
`backend/app.py`.

## Layout

```
app.py                    entry point — runs from the project root
                          via `streamlit run app.py`

backend/                  Streamlit / Python package
├── __init__.py
├── ui.py                 theme tokens, page CSS injection, hero banner
└── sidebar.py            sidebar content + parameter input specs

frontend/                 browser-side static assets
├── hero.html             Canvas + vanilla-JS animation (loaded into an
│                         iframe by ui.apply_page_chrome)
└── page.css              page-wide CSS template (themed via __VARS__
                          substitution at runtime)

.streamlit/
└── config.toml           offline-friendly Streamlit defaults

environment.yml
requirements.txt
README.md
```

## Setup (needs internet once)

```bash
conda env create -f environment.yml
conda activate prsim
```

## Run (no internet required)

```bash
streamlit run app.py
```

## Offline-self-sufficient

After the one-time env install, nothing in the app pulls from the internet
at runtime:

- No external `<script src>` or `<link rel="stylesheet">` in `hero.html`.
- No CDN-loaded webfonts. The sun/moon glyphs in the theme toggle (☀/🌙)
  come from the OS font; the banner title uses Arial / sans-serif.
- `.streamlit/config.toml` disables analytics and uses the minimal toolbar.
- The Canvas animation is rendered locally with vanilla JS — no D3,
  no Three.js, no remote shaders.

## Adding a sidebar parameter

Edit `backend/sidebar.py` — add one new line to `FEE_SPECS`:



```python
NumericParamSpec("my_new_param", 1.50, 0.10, max_value=100.0),
```

The new input appears in the sidebar; its value is accessible downstream
as `params["my_new_param"]` (return of `render_sidebar()`) or
`st.session_state.my_new_param`.

## Tuning the banner animation

Edit `backend/ui.py` — values in `SIM_CONFIG` (walker count, lifetime,
amplitude, etc.) are JSON-injected into `frontend/hero.html`.
