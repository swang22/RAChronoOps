"""
mp_figure_style.py

Authoritative style definitions for market-pattern storage MCS variants.
Import this module in any figure script that plots MP_pure_cur or MP_emergency_cur.

Do not use blue or green for either MP method: those colors are reserved for
Event-window (blue) and Emergency-only (green) core methods.
"""

MP_STYLE = {
    "MP_pure_cur": {
        "label":     "Market-pattern",
        "color":     "#795548",   # sienna brown
        "marker":    "v",
        "linestyle": "-",
        "alpha":     0.88,
    },
    "MP_emergency_cur": {
        "label":     "Market-pattern + emergency",
        "color":     "#4E342E",   # dark brown
        "marker":    "p",
        "linestyle": "--",
        "alpha":     0.92,
    },
}
