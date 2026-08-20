#!/usr/bin/env python3
# Builds the share cards in docs/images/ from the page's own type and colors,
# plus the tui.png screenshot.
#
# Two files, because the consumers ask for two ratios:
#
#   social-preview.png  1280x640, 2:1     The Social preview field under the
#                                         repo's Settings > General, and
#                                         twitter:image. GitHub documents 1280
#                                         by 640 as "best display" and rejects
#                                         a file over 1 MB. X's
#                                         summary_large_image card requires
#                                         2:1, from 300x157 up to 4096x4096.
#   social-og.png       1200x630, 1.91:1  og:image, read by Facebook,
#                                         LinkedIn, Slack, Mastodon and
#                                         iMessage. Facebook documents 1200 by
#                                         630 and asks for a ratio as close to
#                                         1.91:1 as possible.
#
# Feeding one file to both crops it. A 2:1 image cropped to 1.91:1 loses 61
# pixels of width, and the screenshot border sits 79 pixels in.
#
# This embeds docs/images/tui.png and docs/images/icon.png, so retaking
# either one leaves both cards showing the old content. The render reproduces
# byte for byte, so a rerun plus `git diff --stat docs/images/` reports it.
#
# Needs Pillow. Every other Python script here reads the standard library
# alone. Needs the two Georgia faces under /System/Library/Fonts/Supplemental,
# so it runs on macOS.
#
# Usage: python3 scripts/docs-social-preview.py

from PIL import Image, ImageDraw, ImageFont, ImageOps

PAPER = (0xFB, 0xFA, 0xF8)
INK = (0x1A, 0x1A, 0x1A)
MUTED = (0x5B, 0x5B, 0x5B)
RULE = (0xD8, 0xD8, 0xD4)

TITLE_TEXT = "Keywise"
LEDE_TEXT = "Reads a Firefox profile's saved logins with no dependencies."
ICON_PATH = "docs/images/icon.png"
SCREENSHOT_PATH = "docs/images/tui.png"

TITLE_FONT_PATH = "/System/Library/Fonts/Supplemental/Georgia Bold.ttf"
LEDE_FONT_PATH = "/System/Library/Fonts/Supplemental/Georgia.ttf"

TARGETS = (
    (1280, 640, "docs/images/social-preview.png"),
    (1200, 630, "docs/images/social-og.png"),
)

MARGIN = 80
ICON_Y = 60


def render(width, height, out_path):
    canvas = Image.new("RGB", (width, height), PAPER)
    draw = ImageDraw.Draw(canvas)

    title_font = ImageFont.truetype(TITLE_FONT_PATH, 52)
    lede_font = ImageFont.truetype(LEDE_FONT_PATH, 27)

    icon = Image.open(ICON_PATH).convert("RGBA")
    canvas.paste(icon, (MARGIN, ICON_Y), icon)

    tb = draw.textbbox((0, 0), TITLE_TEXT, font=title_font)
    title_h = tb[3] - tb[1]
    title_x = MARGIN + icon.width + 22
    title_y = ICON_Y + (icon.height - title_h) // 2 - tb[1]
    draw.text((title_x, title_y), TITLE_TEXT, font=title_font, fill=INK)

    lede_y = ICON_Y + icon.height + 26
    draw.text((MARGIN, lede_y), LEDE_TEXT, font=lede_font, fill=MUTED)

    content_w = width - 2 * MARGIN
    tui = Image.open(SCREENSHOT_PATH).convert("RGB")
    scale = content_w / tui.width
    tui_resized = tui.resize((content_w, round(tui.height * scale)), Image.LANCZOS)
    tui_bordered = ImageOps.expand(tui_resized, border=1, fill=RULE)

    shot_y = lede_y + 60
    canvas.paste(tui_bordered, (MARGIN - 1, shot_y))

    bottom = shot_y + tui_bordered.height
    # The layout runs top to bottom from a fixed margin, so a canvas shorter
    # than the content clips the screenshot instead of scaling it.
    if bottom > height:
        raise SystemExit(f"{out_path}: content reaches {bottom} in a {height} canvas")

    canvas.save(out_path)
    return bottom


def build():
    for width, height, out_path in TARGETS:
        bottom = render(width, height, out_path)
        print(f"saved {out_path} {width}x{height}, screenshot bottom at {bottom}")


if __name__ == "__main__":
    build()
